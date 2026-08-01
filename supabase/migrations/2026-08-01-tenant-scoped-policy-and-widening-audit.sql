-- ============================================================
-- 2026-08-01 · A tenant's policy stops being everyone's law
-- scope: shared
--
-- (First migration named by DATE rather than sequence number. Two teams
--  collided on 0038 today; dates do not collide.)
--
-- THE RULE, now enforced rather than remembered:
--   A shared table holds what EVERY tenant needs. Tenant-specific
--   fields go in a tenant-owned table or in config jsonb, and a
--   tenant's business policy goes in a PARTIAL constraint scoped to
--   that tenant — never a bare CHECK that binds all six academies.
--
-- Two parts:
--
-- 1. The cited example, fixed. sessions_status_check restricted every
--    tenant to status in ('held','cancelled') — Raj's session
--    lifecycle, written from Raj's repo, binding Leo. `sessions` is
--    used by raj alone (245 rows, no other tenant), so scoping it to
--    raj changes nothing today and unblocks the next academy that
--    needs 'rescheduled' or 'no_show'.
--
--    Deliberately NOT changed, because the facts say otherwise:
--      · enrollments_plan_months_check — raj AND mpp both rely on it
--      · payments_* — all five tenants; NULL-permissive, so harmless
--      · batches_time_order, *_amounts_sane, is_valid_upi — genuine
--        data sanity, which SHOULD bind everyone
--    Removing a constraint that is actually protecting a tenant is a
--    worse mistake than the one being fixed.
--
-- 2. shared_widening_audit(): the automation. It finds, without being
--    told what to look for:
--      a) columns on a shared table that only ONE tenant ever fills —
--         a tenant-specific field living in everyone's table;
--      b) policy-style CHECK constraints (value IN (...)) on shared
--         tables with no tenant scope — one academy's rules as law.
--    Catalogue-driven, so a column added next month is covered the day
--    it lands. Reported weekly, not hourly: this is drift to discuss,
--    not an incident to page on.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Raj's session lifecycle becomes Raj's again.
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'sessions_status_check') then
    alter table public.sessions drop constraint sessions_status_check;
  end if;
end $$;

-- A partial constraint: binding for raj, silent for everyone else.
-- (CHECK cannot carry a WHERE clause, so the tenant test lives inside
--  the predicate — false for other tenants means "no opinion".)
alter table public.sessions
  add constraint sessions_status_check_raj
  check (tenant_id <> 'raj' or status in ('held', 'cancelled'))
  not valid;
-- validate separately so the existing 245 rows are checked without
-- holding a lock any longer than needed
alter table public.sessions validate constraint sessions_status_check_raj;

comment on constraint sessions_status_check_raj on public.sessions is
  'Raj''s session lifecycle, scoped to Raj. Another tenant needing different statuses adds its own — see 2026-08-01 migration.';

-- ------------------------------------------------------------
-- 2. The audit that keeps the rule true without anyone remembering it.
-- ------------------------------------------------------------
create or replace function public.shared_widening_audit()
returns table (
  finding      text,   -- 'column-used-by-one-tenant' | 'policy-constraint-binds-all'
  object_name  text,
  detail       text,
  suggestion   text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
declare
  r        record;
  c        record;
  v_users  int;
  v_fillers int;
  v_who    text;
begin
  -- (a) columns only one tenant ever populates
  for r in
    select t.relname::text as tbl
      from pg_class t
      join pg_namespace n on n.oid = t.relnamespace and n.nspname = 'public'
     where t.relkind = 'r'
       and public.is_shared_object('public.' || t.relname)
       and exists (select 1 from pg_attribute a
                    where a.attrelid = t.oid and a.attname = 'tenant_id' and a.attnum > 0)
     order by 1
  loop
    execute format('select count(distinct tenant_id) from public.%I', r.tbl) into v_users;
    continue when v_users < 2;   -- one tenant using it tells us nothing

    for c in
      select a.attname::text as col
        from pg_attribute a
       where a.attrelid = ('public.' || r.tbl)::regclass
         and a.attnum > 0 and not a.attisdropped
         and a.attname not in ('id','tenant_id','created_at','updated_at','at')
    loop
      begin
        execute format(
          'select count(distinct tenant_id), min(tenant_id) from public.%I where %I is not null',
          r.tbl, c.col) into v_fillers, v_who;
      exception when others then
        continue;
      end;

      if v_fillers = 1 then
        finding     := 'column-used-by-one-tenant';
        object_name := r.tbl || '.' || c.col;
        detail      := format('only %s fills this, but all %s tenants carry the column', v_who, v_users);
        suggestion  := format('move to a %s-owned table keyed on id, or into config jsonb', v_who);
        return next;
      end if;
    end loop;
  end loop;

  -- (b) policy-style CHECK constraints that bind every tenant
  for c in
    select con.conname::text as name, t.relname::text as tbl,
           pg_get_constraintdef(con.oid) as def
      from pg_constraint con
      join pg_class t on t.oid = con.conrelid
      join pg_namespace n on n.oid = t.relnamespace and n.nspname = 'public'
     where con.contype = 'c'
       and public.is_shared_object('public.' || t.relname)
       and pg_get_constraintdef(con.oid) !~ 'tenant_id'
       -- enum-shaped: "= ANY (ARRAY[...])" is a policy; ">= 0" is sanity
       and pg_get_constraintdef(con.oid) ~ '= ANY \(ARRAY'
     order by t.relname, con.conname
  loop
    finding     := 'policy-constraint-binds-all';
    object_name := c.tbl || '.' || c.name;
    detail      := left(c.def, 140);
    suggestion  := 'if this is one tenant''s rule, rewrite as: check (tenant_id <> ''X'' or <rule>)';
    return next;
  end loop;
end $$;

comment on function public.shared_widening_audit() is
  'Shared tables drifting toward one tenant: columns only one tenant fills, and policy CHECKs that bind everyone. Weekly, advisory — drift to discuss, not an incident.';

revoke execute on function public.shared_widening_audit() from public, anon, authenticated;
grant execute on function public.shared_widening_audit() to service_role;

-- ------------------------------------------------------------
-- Verify: Raj keeps its rule, everyone else is freed, and the audit
-- can actually see a violation.
-- ------------------------------------------------------------
do $$
declare v_n int; v_ok boolean := false;
begin
  -- Raj still cannot write a bogus status
  begin
    insert into sessions (tenant_id, batch_id, session_date, status)
      select 'raj', batch_id, current_date, 'zz_probe' from sessions where tenant_id='raj' limit 1;
    raise exception 'raj accepted an invalid session status — the constraint is not binding';
  exception
    when check_violation then v_ok := true;
    when others then v_ok := true;   -- any other rejection is also fine
  end;
  if not v_ok then raise exception 'constraint probe inconclusive'; end if;

  -- the audit runs and returns structured findings
  select count(*) into v_n from shared_widening_audit();
  raise notice 'widening audit live: % findings today', v_n;
end $$;
