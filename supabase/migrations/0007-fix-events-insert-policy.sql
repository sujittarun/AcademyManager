-- ============================================================
-- 0007 · Restore anonymous event writes
-- scope: shared
--
-- 0003 tightened events_public_w to reject writes for a tenant that
-- does not exist:
--
--   exists (select 1 from tenants t where t.id = events.tenant_id)
--
-- A policy predicate is evaluated AS THE CALLING ROLE. anon has no
-- select policy on `tenants`, so that subquery returns no rows for
-- every tenant, existing or not, and the whole predicate is false. The
-- policy did not tighten event writes — it stopped them.
--
-- This is the same mistake as 0004: a predicate that depends on
-- something the role cannot see. 0003 itself already used the right
-- pattern for exactly this reason (tenant_publishes_timetable is
-- SECURITY DEFINER precisely because anon cannot read `tenants`) and
-- then I failed to apply it three lines further down.
--
-- Measured, not assumed:
--   24h before 0003 (applied 2026-07-29 08:36 UTC) — 97 events
--   since                                          —  0 events
--
-- So every tenant's page_view analytics AND every tenant's client error
-- reporting were silently off for the whole window. Silently, because a
-- rejected telemetry POST is deliberately swallowed by the client — the
-- one thing that must never break the app is also the one thing that
-- cannot complain when it breaks.
-- ============================================================

-- ------------------------------------------------------------
-- The lookup anon cannot do for itself.
-- ------------------------------------------------------------
create or replace function public.tenant_exists(p_tenant text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (select 1 from tenants t where t.id = p_tenant)
$$;

comment on function public.tenant_exists(text) is
  'True when a tenant id is registered. SECURITY DEFINER because anon cannot read tenants.';

grant execute on function public.tenant_exists(text) to anon, authenticated, service_role;

drop policy if exists events_public_w on events;
create policy events_public_w on events
  for insert to anon
  with check (
    tenant_id is not null
    and public.tenant_exists(tenant_id)
    and name is not null
    and length(name) <= 64
  );

-- ------------------------------------------------------------
-- A canary, because rls_audit() cannot catch this class.
--
-- rls_audit checks policy SHAPE — whether tenant_id appears in the
-- predicate. It did, so this passed cleanly while the platform was
-- deaf. Shape checks cannot see behaviour; only traffic can.
--
-- The platform normally takes ~100 events a day. Twelve silent hours
-- after a week of traffic means a write path is broken, whatever the
-- policies look like. Guarded on there having been traffic at all, so
-- this never fires for a genuinely idle platform.
-- ------------------------------------------------------------
create or replace function public.events_flowing()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select not (
    not exists (select 1 from events where at > now() - interval '12 hours')
    and     exists (select 1 from events where at > now() - interval '8 days')
  )
$$;

comment on function public.events_flowing() is
  'False when the events sink has gone quiet for 12h despite recent traffic — i.e. anon writes are broken.';

revoke all on function public.events_flowing() from anon, authenticated;
grant execute on function public.events_flowing() to service_role;

-- ------------------------------------------------------------
-- Hourly check gains the canary. Body is 0005's verbatim, appended to.
-- ------------------------------------------------------------
create or replace function public.cron_health_check()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_gaps int; v_failed int; v_unscoped int; v_errs int; v_tenants text;
begin
  select count(*) into v_failed from sync_jobs where status='failed';
  select count(*) into v_gaps from (
    select 1 from bookings b
    join integrations i on i.tenant_id=b.tenant_id and i.enabled and i.channel<>b.source
    where b.date=current_date and b.status='confirmed' and b.court is not null
      and not exists (select 1 from sync_log sl where sl.tenant_id=b.tenant_id and sl.channel=i.channel
        and sl.action='push' and sl.status='ok'
        and sl.detail like '%'||b.court||'%'||current_date::text||'%'||b.hour||':00%')
  ) g;
  if v_gaps>0 or v_failed>0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','reconcile', case when v_failed>0 then 'error' else 'warn' end,
        v_gaps||' propagation gap(s), '||v_failed||' failed job(s)');
  end if;

  -- appended by 0003: an anon policy with no tenant_id in its predicate
  select count(*) into v_unscoped from rls_audit();
  if v_unscoped > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rls_audit','error',
        v_unscoped||' anon policy/policies with no tenant filter: '||
        (select string_agg(tbl||'.'||policy_name, ', ') from rls_audit()));
  end if;

  -- appended by 0005: distinct client errors in the last hour
  select count(*), string_agg(distinct tenant_id, ', ')
    into v_errs, v_tenants
    from platform_errors(1);
  if v_errs > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','client_errors','warn',
        v_errs||' distinct client error(s) in the last hour: '||coalesce(v_tenants,'?'));
  end if;

  -- appended by 0007: the sink itself has gone quiet
  if not events_flowing() then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','events_sink','error',
        'no events for 12h despite traffic in the past week — anon writes are likely broken');
  end if;
end $function$;

-- ------------------------------------------------------------
-- Prove it, in the same transaction that made the change, rather than
-- trusting that it reads correctly.
-- ------------------------------------------------------------
do $$
begin
  if not public.tenant_exists('leo')  then raise exception 'tenant_exists false for a real tenant'; end if;
  if not public.tenant_exists('mpp')  then raise exception 'tenant_exists false for mpp'; end if;
  if     public.tenant_exists('nope') then raise exception 'tenant_exists true for an unknown tenant'; end if;
end $$;
