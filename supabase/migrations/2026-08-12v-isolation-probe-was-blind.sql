-- ============================================================
-- 2026-08-12v · The isolation probe reported ok while testing nothing
-- scope: shared
--
-- 2026-08-12u added tenant_isolation_probe() and it passed. It passed
-- because it did nothing.
--
--     called as authenticated → ok, "0 tenant/table combinations probed"
--
-- The outer loop is `for r_tenant in select id from tenants`. The
-- function is SECURITY INVOKER by design — it has to be, so that RLS
-- applies — and `authenticated` cannot read `tenants`. So the loop
-- iterated zero times, `leaked` stayed 0, and the function returned
-- "ok". A probe that cannot reach its own worklist reports a clean bill
-- of health for a database it never looked at.
--
-- Caught by the self-test rather than by review: a deliberate
-- `USING (true)` policy was planted on public.members and the probe
-- still said ok. That is the only reason this file exists, and it is
-- the argument for always asking a new check to fail on purpose before
-- trusting it to pass.
--
-- TWO FIXES, and the second matters more than the first.
--
--   1. The worklist comes from a definer helper, so the probe can see
--      which tenants exist without being able to read `tenants` itself.
--
--   2. `probed = 0` is now INCONCLUSIVE, never ok. Any future reason the
--      loop runs dry — a renamed table, a revoked grant, a tenant list
--      that comes back empty — surfaces as "could not test" instead of
--      as a pass. The failure mode this file fixes must not be able to
--      recur silently, only loudly.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The worklist, readable without reading `tenants`
-- ------------------------------------------------------------
create or replace function tenant_ids()
returns text[]
language sql
stable
security definer
set search_path = public
as $$ select coalesce(array_agg(id order by id), '{}') from tenants $$;

comment on function tenant_ids() is
  'Just the tenant ids. Exists so an invoker-rights check can enumerate tenants without being able to SELECT from `tenants` — reading the list is not the same privilege as reading the configs, which hold WhatsApp numbers and billing.';

revoke execute on function tenant_ids() from public, anon;
grant  execute on function tenant_ids() to authenticated, service_role;

-- ------------------------------------------------------------
-- 2. The probe, no longer able to pass by doing nothing
-- ------------------------------------------------------------
create or replace function tenant_isolation_probe()
returns table (check_name text, verdict text, detail text)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_tenants text[];
  v_tenant  text;
  r_tbl     record;
  n         bigint;
  leaked    int := 0;
  probed    int := 0;
begin
  if current_setting('is_superuser', true) = 'on'
     or exists (select 1 from pg_roles
                 where rolname = current_user and (rolsuper or rolbypassrls)) then
    check_name := 'tenant isolation';
    verdict    := 'INCONCLUSIVE';
    detail     := format('ran as %s, which bypasses RLS — call it with `set role authenticated`', current_user);
    return next; return;
  end if;

  v_tenants := tenant_ids();

  foreach v_tenant in array v_tenants loop
    perform set_config('request.jwt.claims', json_build_object(
      'role','authenticated',
      'sub', gen_random_uuid()::text,
      'app_metadata', json_build_object('am_role','staff','tenant_id', v_tenant)
    )::text, true);

    for r_tbl in
      select unnest(array['members','payments','enrollments','bookings',
                          'attendance_records','reminder_events','expenses']) t
    loop
      begin
        if r_tbl.t = 'attendance_records' then
          execute format(
            'select count(*) from attendance_records ar
               where exists (select 1 from sessions s
                              where s.id = ar.session_id and s.tenant_id <> %L)', v_tenant)
            into n;
        else
          execute format('select count(*) from %I where tenant_id <> %L', r_tbl.t, v_tenant)
            into n;
        end if;
        probed := probed + 1;          -- only counts a query that RAN
      exception when others then
        n := 0;                        -- unreachable table is not a leak
      end;

      if n > 0 then
        leaked := leaked + 1;
        check_name := format('%s staff reading other tenants'' %s', v_tenant, r_tbl.t);
        verdict    := 'LEAK';
        detail     := format('%s row(s) visible that belong to another tenant', n);
        return next;
      end if;
    end loop;

    perform set_config('request.jwt.claims', null, true);
  end loop;

  -- Nothing probed is not a pass. This is the bug 2026-08-12u shipped.
  if probed = 0 then
    check_name := 'tenant isolation';
    verdict    := 'INCONCLUSIVE';
    detail     := format('probed nothing — %s tenant(s) in the worklist. A green result here would be a lie.',
                         coalesce(array_length(v_tenants,1), 0));
    return next; return;
  end if;

  if leaked = 0 then
    check_name := 'tenant isolation';
    verdict    := 'ok';
    detail     := format('%s tenant/table combinations probed across %s tenants, every one returned 0 foreign rows',
                         probed, coalesce(array_length(v_tenants,1),0));
    return next;
  end if;
end $$;

revoke execute on function tenant_isolation_probe() from public, anon;
grant  execute on function tenant_isolation_probe() to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks — the probe must FAIL on demand before its pass means anything
-- ------------------------------------------------------------
do $$
declare v_verdict text; v_detail text; n_leak int; n_probed int;
begin
  -- a) a bypassing role gets no verdict
  select verdict into v_verdict from tenant_isolation_probe() limit 1;
  if v_verdict <> 'INCONCLUSIVE' then
    raise exception 'postgres got verdict "%" — the bypass guard is not working', v_verdict;
  end if;

  -- b) as authenticated it must actually probe something
  set local role authenticated;
  select verdict, detail into v_verdict, v_detail from tenant_isolation_probe() limit 1;
  reset role;
  if v_verdict = 'INCONCLUSIVE' then
    raise exception 'still testing nothing: %', v_detail;
  end if;
  n_probed := (regexp_match(v_detail, '^([0-9]+) tenant/table'))[1]::int;
  if coalesce(n_probed,0) < 20 then
    raise exception 'only % combinations probed; expected 6 tenants x 7 tables', n_probed;
  end if;

  -- c) and it must SEE a leak that is deliberately planted
  create policy iso_selftest on public.members for select to authenticated using (true);
  set local role authenticated;
  select count(*) into n_leak from tenant_isolation_probe() where verdict = 'LEAK';
  reset role;
  drop policy iso_selftest on public.members;

  if n_leak = 0 then
    raise exception 'a USING(true) policy on members was planted and the probe did not notice — it is blind';
  end if;
  raise notice 'probe caught the planted leak in % place(s), and reports ok without it: %', n_leak, v_detail;

  -- d) the planted policy is gone again
  if exists (select 1 from pg_policy p join pg_class c on c.oid=p.polrelid
              where c.relname='members' and p.polname='iso_selftest') then
    raise exception 'the self-test policy was left behind on members';
  end if;
end $$;
