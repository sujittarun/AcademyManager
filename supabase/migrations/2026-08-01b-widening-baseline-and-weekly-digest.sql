-- ============================================================
-- 2026-08-01b · Make the widening audit usable, and automate the week
-- scope: shared
--
-- The audit shipped an hour ago returns 42 findings. Most are noise:
-- members.dob and bookings.phone are perfectly good universal columns
-- that only one tenant has filled *so far*. Shipping a weekly report
-- that opens with 42 items nobody will action is how a watchdog becomes
-- wallpaper — the same mistake 0034 was written to avoid.
--
-- Same fix that made ddl_log usable: BASELINE what exists today, then
-- report only what is NEW. A column added next month by one tenant
-- stands alone in the report, which is exactly when the question
-- "should this live in a shared table?" is cheap to answer.
--
-- Then the weekly digest itself, so point 4 stops being a discipline
-- and becomes a job: every Monday, one row in sync_log summarising what
-- the six teams did to the shared surface, and what still needs a human.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The review ledger. A finding is noise once; it is signal the
--    first time it appears.
-- ------------------------------------------------------------
create table if not exists public.shared_surface_review (
  object_name text primary key,
  finding     text not null,
  detail      text,
  first_seen  timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by text,
  note        text
);
alter table public.shared_surface_review enable row level security;
revoke all on table public.shared_surface_review from public, anon, authenticated;
comment on table public.shared_surface_review is
  'Widening-audit findings, once each. reviewed_at set = accepted or actioned; NULL = new drift needing a decision.';

-- ------------------------------------------------------------
-- 2. Record findings, return only the unreviewed ones.
-- ------------------------------------------------------------
create or replace function public.shared_widening_new()
returns table (finding text, object_name text, detail text, suggestion text)
language plpgsql
security definer
set search_path to 'public'
as $$
-- the OUT parameters share names with the ledger's columns; inside the
-- body, a bare name means the COLUMN
#variable_conflict use_column
begin
  insert into public.shared_surface_review (object_name, finding, detail)
  select a.object_name, a.finding, a.detail
    from shared_widening_audit() a
  on conflict (object_name) do nothing;

  return query
    select r.finding, r.object_name, r.detail,
           case r.finding
             when 'column-used-by-one-tenant'  then 'move to a tenant-owned table, or config jsonb'
             else 'if this is one tenant''s rule: check (tenant_id <> ''X'' or <rule>)'
           end
      from public.shared_surface_review r
     where r.reviewed_at is null
     order by r.first_seen, r.object_name;
end $$;
revoke execute on function public.shared_widening_new() from public, anon, authenticated;
grant execute on function public.shared_widening_new() to service_role;

-- Baseline: everything true today is accepted history, not drift.
insert into public.shared_surface_review (object_name, finding, detail, reviewed_at, reviewed_by, note)
select a.object_name, a.finding, a.detail, now(), 'baseline 2026-08-01',
       'Pre-existing when the audit was written. Universal-but-unused columns and platform-wide policy constraints both land here; revisit only if the table is refactored.'
  from shared_widening_audit() a
on conflict (object_name) do update
  set reviewed_at = coalesce(public.shared_surface_review.reviewed_at, excluded.reviewed_at),
      reviewed_by = coalesce(public.shared_surface_review.reviewed_by, excluded.reviewed_by),
      note        = coalesce(public.shared_surface_review.note, excluded.note);

-- ------------------------------------------------------------
-- 3. The weekly digest. One place that answers "what happened to the
--    shared surface this week, and what needs me?"
-- ------------------------------------------------------------
create or replace function public.weekly_digest(p_days int default 7)
returns jsonb
language sql
stable
-- SECURITY INVOKER, deliberately: it calls anon_probe(), which does
-- `set local role anon`, and Postgres forbids that inside a definer
-- function (a definer that can change role is a privilege ladder).
-- So this runs as its caller — cron runs as postgres, which can.
set search_path to 'public'
as $$
  select jsonb_build_object(
    'window_days', p_days,
    'generated_at', now(),

    -- what needs a human, in priority order
    'needs_attention', jsonb_build_object(
      'cross_tenant_rows',      (select count(*) from cross_tenant_integrity()),
      'schema_changed_outside_runner',
                                (select count(*) from schema_drift(p_days) where via = 'BYPASSED THE RUNNER'),
      'unsafe_anon_policies',   (select count(*) from rls_audit()),
      'anon_callable_definers', (select count(*) from rpc_audit()),
      'probe_failures',         (select count(*) from anon_probe() where verdict <> 'ok'),
      'new_shared_surface_drift', (select count(*) from shared_surface_review where reviewed_at is null)
    ),

    -- what the teams shipped, per scope
    'migrations_by_scope', coalesce((
      select jsonb_object_agg(scope, n) from (
        select scope, count(*) n from schema_migrations
         where applied_at >= now() - make_interval(days => p_days)
         group by scope) s), '{}'::jsonb),

    -- shared-object DDL, whoever ran it
    'shared_ddl', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', to_char(at,'MM-DD HH24:MI'), 'object', obj_name,
               'command', command, 'via', via))
        from (select * from schema_drift(p_days) limit 25) d), '[]'::jsonb),

    -- tenant activity, so a quiet academy is visible
    'tenant_activity', coalesce((
      select jsonb_object_agg(t.id, jsonb_build_object(
               'events',   (select count(*) from events e
                             where e.tenant_id = t.id and e.at >= now() - make_interval(days => p_days)),
               'payments', (select count(*) from payments p
                             where p.tenant_id = t.id and p.created_at >= now() - make_interval(days => p_days))))
        from tenants t), '{}'::jsonb)
  )
$$;

comment on function public.weekly_digest(int) is
  'One object answering: what needs a human, what each team shipped, what touched the shared surface, and which academies were active.';
revoke execute on function public.weekly_digest(int) from public, anon, authenticated;
grant execute on function public.weekly_digest(int) to service_role;

-- ------------------------------------------------------------
-- 4. Monday 07:00 UTC (12:30 IST): write it where the operator looks.
-- ------------------------------------------------------------
-- Also invoker-rights, for the same reason: it calls weekly_digest(),
-- which reaches anon_probe(). cron runs as postgres.
create or replace function public.cron_weekly_digest()
returns void language plpgsql set search_path to 'public' as $$
declare d jsonb; v_att jsonb; v_sum int;
begin
  d := weekly_digest(7);
  v_att := d->'needs_attention';
  select sum(value::int) into v_sum
    from jsonb_each_text(v_att);

  insert into sync_log (tenant_id, channel, action, status, detail)
    values ('platform','*','weekly_digest',
            case when v_sum > 0 then 'warn' else 'ok' end,
            d::text);
end $$;
revoke execute on function public.cron_weekly_digest() from public, anon, authenticated;

select cron.schedule('weekly-digest-monday', '0 7 * * 1',
                     $cron$select public.cron_weekly_digest()$cron$);

-- ------------------------------------------------------------
-- Verify: baseline silences today's noise, the digest is well-formed.
-- ------------------------------------------------------------
do $$
declare v_new int; v_total int; d jsonb;
begin
  select count(*) into v_total from shared_surface_review;
  select count(*) into v_new   from shared_widening_new();
  if v_new > 0 then
    raise exception 'baseline failed: % findings still unreviewed', v_new;
  end if;

  d := weekly_digest(7);
  if d->'needs_attention' is null or d->'tenant_activity' is null then
    raise exception 'digest is missing sections';
  end if;

  raise notice 'baselined % findings; digest live; new drift will stand alone', v_total;
end $$;
