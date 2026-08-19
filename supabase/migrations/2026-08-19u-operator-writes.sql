-- ============================================================
-- 2026-08-19u · The owner can already READ every academy. Now he can write.
-- scope: shared
--
-- Measured before writing this, because anything touching policies has to
-- be measured before and after rather than reasoned about:
--
--   as operator, SELECT  ->  every tenant table already returns every row
--   assert_staff('raj')  ->  passes
--   mark_attendance, reminder_queue, record_fee_payment -> all work
--   INSERT into members  ->  "new row violates row-level security policy"
--
-- So the only gap is direct table writes: 59 policies named
-- `<table>_staff_<w|u|d>` test `auth_role() = 'staff'` and nothing else.
-- Adding a student or an expense from a tenant app therefore fails for
-- the owner while everything else works — the worst kind of half-working,
-- because it looks like a bug in the app rather than a permission.
--
-- WHY A NEW POLICY PER TABLE RATHER THAN EDITING 59 PREDICATES.
-- Permissive policies are OR'd. One extra policy grants the operator what
-- he needs and leaves every existing predicate byte-for-byte untouched,
-- so there is no way for this migration to break a tenant's own staff
-- access — the failure mode that has taken this platform down twice. It
-- is also one line per table to drop if it is ever regretted.
--
-- SCOPED TO `authenticated`, NOT `public`. A policy `to public` also
-- applies to anon; anon's auth_role() is '' so it would evaluate false,
-- but a shape audit cannot see that and rls_audit() would light up. Say
-- what is meant.
--
-- WHAT THIS COSTS, stated plainly rather than buried: an operator JWT now
-- writes to every academy. That token lives in a browser, unlike
-- service_role. The owner already administers this database directly, so
-- what widens is the exposure surface, not the authority — but it IS a
-- real widening, decided deliberately on 2026-08-19 so six apps can be
-- demonstrated without six logins.
--
-- `tenants` is the 33rd table with staff policies and is deliberately
-- left alone: academy config is what the operator console and
-- set_subscription() are for, and neither needs a blanket policy.
-- ============================================================

do $$
declare r record; n int := 0;
begin
  for r in
    select c.relname as tbl
      from pg_class c
      join pg_namespace nsp on nsp.oid = c.relnamespace
      join pg_policy p on p.polrelid = c.oid
     where nsp.nspname = 'public'
       and c.relkind = 'r'
       and c.relrowsecurity
       and p.polname like '%\_staff\_%'
       and exists (select 1 from information_schema.columns col
                    where col.table_schema = 'public'
                      and col.table_name = c.relname
                      and col.column_name = 'tenant_id')
     group by c.relname
     order by c.relname
  loop
    execute format('drop policy if exists %I on public.%I', r.tbl || '_operator_all', r.tbl);
    execute format(
      'create policy %I on public.%I as permissive for all to authenticated '
      || 'using (auth_role() = ''operator'') with check (auth_role() = ''operator'')',
      r.tbl || '_operator_all', r.tbl);
    n := n + 1;
  end loop;
  if n < 25 then
    raise exception 'only % tables matched; expected ~32. Check the catalogue query before trusting this', n;
  end if;
  raise notice 'operator write policy added to % tables', n;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $chk$
declare n int; msg text; m_id bigint; leaked int;
begin
  -- a) the gap this file exists to close
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  set local role authenticated;
  begin
    insert into members (tenant_id, name, status, joined)
    values ('raj', 'ZZ Operator Probe', 'active', current_date) returning id into m_id;
  exception when others then
    get stacked diagnostics msg = message_text;
    reset role;
    raise exception 'the operator still cannot write: %', msg;
  end;
  update members set name = 'ZZ Operator Probe 2' where id = m_id;
  reset role;
  delete from members where id = m_id;              -- an assertion that writes must clean up
  if exists (select 1 from members where id = m_id) then
    raise exception 'the probe row was left behind';
  end if;

  -- b) a TENANT's staff must not have gained anything. This is the check
  --    that matters: 32 tables just got a new policy, and the whole point
  --    of adding one instead of editing 59 was to not disturb these.
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','staff','tenant_id','raj'))::text, true);
  set local role authenticated;
  select count(*) into leaked from members where tenant_id <> 'raj';
  reset role;
  if leaked > 0 then
    raise exception 'raj staff can now see % of another academy''s members', leaked;
  end if;

  -- c) and a tenant's staff still cannot write into another academy
  set local role authenticated;
  begin
    insert into members (tenant_id, name, status, joined)
    values ('leo', 'ZZ Cross Tenant', 'active', current_date);
    n := 1;
  exception when others then n := 0;
  end;
  reset role;
  if n = 1 then
    delete from members where tenant_id = 'leo' and name = 'ZZ Cross Tenant';
    raise exception 'raj staff was able to write into leo';
  end if;

  -- d) anon gained nothing at all
  perform set_config('request.jwt.claims', null, true);
  set local role anon;
  begin select count(*) into n from members; exception when others then n := 0; end;
  reset role;
  if n > 0 then raise exception 'anon can read % members', n; end if;

  -- e) the shape audits stay clean
  if (select count(*) from rls_audit()) > 0 then
    raise exception 'rls_audit() is no longer empty';
  end if;

  raise notice 'operator writes; raj staff unchanged; anon still sees nothing';
end $chk$;
