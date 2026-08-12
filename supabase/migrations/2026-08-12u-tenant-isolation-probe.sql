-- ============================================================
-- 2026-08-12u · Nothing tested that a signed-in tenant stays in its lane
-- scope: shared
--
-- Prompted by a line in an audit write-up: "any demo credential is a key
-- to every tenant's families." Checked, and it is not true here — a
-- staff JWT for `demo` reads 94 of its own members and 0 of anyone
-- else's, and reminder_queue('genalpha') refuses it outright. The
-- sentence described GenAlpha's OWN project, where 23 policies were
-- `authenticated USING (true)`, so any signed-in account could read all
-- 81 families. That project was deleted on 2026-08-12.
--
-- The uncomfortable part is not the finding. It is that checking it
-- required writing a one-off query, because THE PLATFORM HAS NO CANARY
-- FOR THIS:
--
--   rls_audit()       reads policy shapes — anon only
--   rpc_audit()       definer functions anon may execute — anon only
--   policy_fn_audit() functions a policy names — anon only
--   anon_probe()      calls real endpoints — anon only
--
-- Every one of them is about the public key. The threat they all miss is
-- the ordinary one: six tenants each with real staff logins, on one
-- database, where the only thing between Leo's manager and GenAlpha's 81
-- families is a WHERE clause. A single policy written without
-- `auth_tenant()` reopens it, and nothing would say so.
--
-- This probe signs in as each tenant in turn and counts what it can see
-- of everyone else. Zero is the only acceptable answer.
--
-- Deliberately behavioural. A shape check cannot see this: the policies
-- looked fine on the morning of the worst leak this platform has had.
-- ============================================================

create or replace function tenant_isolation_probe()
returns table (check_name text, verdict text, detail text)
language plpgsql
-- INVOKER, not definer, for two reasons that both matter:
--   * PostgreSQL forbids `set role` inside a definer function, and the
--     probe has to become each tenant to mean anything;
--   * a definer function runs as its owner, and this owner bypasses RLS,
--     so it would read every tenant's rows and report a leak that is not
--     there — or worse, be "fixed" by loosening something real.
-- The caller must already be a role RLS applies to. The guard below
-- refuses to answer otherwise, because a green result from a
-- bypassing role is a lie, not a pass.
security invoker
set search_path = public
as $$
declare
  r_tenant record;
  r_tbl    record;
  v_uid    uuid;
  n        bigint;
  leaked   int := 0;
  probed   int := 0;
begin
  -- Refuse to produce a verdict from a role that cannot fail the test.
  if current_setting('is_superuser', true) = 'on'
     or exists (select 1 from pg_roles
                 where rolname = current_user and (rolsuper or rolbypassrls)) then
    check_name := 'tenant isolation';
    verdict    := 'INCONCLUSIVE';
    detail     := format('ran as %s, which bypasses RLS — call it with `set role authenticated`', current_user);
    return next;
    return;
  end if;

  for r_tenant in select id from tenants order by id loop
    -- Borrow a real staff uid for this tenant when one exists, so the
    -- claims look like a genuine session rather than a synthetic one.
    select u.id into v_uid
      from auth.users u
     where u.raw_app_meta_data->>'tenant_id' = r_tenant.id
     limit 1;

    perform set_config('request.jwt.claims', json_build_object(
      'role','authenticated',
      'sub', coalesce(v_uid, gen_random_uuid())::text,
      'app_metadata', json_build_object('am_role','staff','tenant_id', r_tenant.id)
    )::text, true);

    for r_tbl in
      select unnest(array['members','payments','enrollments','bookings',
                          'attendance_records','reminder_events','expenses']) t
    loop
      begin
        if r_tbl.t = 'attendance_records' then
          -- no tenant_id of its own; it hangs off sessions
          execute format(
            'select count(*) from attendance_records ar
               where exists (select 1 from sessions s
                              where s.id = ar.session_id and s.tenant_id <> %L)', r_tenant.id)
            into n;
        else
          execute format('select count(*) from %I where tenant_id <> %L', r_tbl.t, r_tenant.id)
            into n;
        end if;
      exception when others then
        n := 0;   -- a table this role cannot reach at all is not a leak
      end;

      probed := probed + 1;
      if n > 0 then
        leaked := leaked + 1;
        check_name := format('%s staff reading other tenants'' %s', r_tenant.id, r_tbl.t);
        verdict    := 'LEAK';
        detail     := format('%s row(s) visible that belong to another tenant', n);
        return next;
      end if;
    end loop;

    perform set_config('request.jwt.claims', null, true);
  end loop;

  if leaked = 0 then
    check_name := 'tenant isolation';
    verdict    := 'ok';
    detail     := format('%s tenant/table combinations probed, every one returned 0 foreign rows', probed);
    return next;
  end if;
end $$;

comment on function tenant_isolation_probe() is
  'Signs in as each tenant''s staff and counts rows belonging to every OTHER tenant across the seven tables that hold member data and money. Zero is the only acceptable answer. Behavioural, because the four existing audits all test anon and none of them would notice one tenant reading another.';

revoke execute on function tenant_isolation_probe() from public, anon;
grant  execute on function tenant_isolation_probe() to authenticated, service_role;

-- ------------------------------------------------------------
-- Hourly, alongside the other canaries, logging where they log
-- ------------------------------------------------------------
do $$
begin
  perform cron.unschedule(jobname) from cron.job where jobname = 'tenant-isolation-hourly';
  -- `set role` is legal in a DO block and illegal in a definer function,
  -- which is the whole reason the probe is shaped this way. sync_log is
  -- written back as the job's own role, after stepping down and up.
  perform cron.schedule('tenant-isolation-hourly', '47 * * * *', $j$
    do $inner$
    declare rec record;
    begin
      set local role authenticated;
      create temp table _iso_out on commit drop as select * from tenant_isolation_probe();
      reset role;
      for rec in select * from _iso_out where verdict <> 'ok' loop
        insert into sync_log (tenant_id, action, detail)
        values ('platform', 'tenant_isolation_leak',
                jsonb_build_object('check', rec.check_name, 'detail', rec.detail));
      end loop;
    end $inner$;
  $j$);
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n_leak int; v_detail text; n int;
begin
  set local role authenticated;
  select count(*) into n_leak from tenant_isolation_probe() where verdict <> 'ok';
  select detail into v_detail from tenant_isolation_probe() limit 1;
  reset role;

  if n_leak > 0 then
    raise exception 'tenant isolation is broken RIGHT NOW: % finding(s)', n_leak;
  end if;
  if v_detail like 'ran as %' then
    raise exception 'the probe could not test anything: %', v_detail;
  end if;
  raise notice '%', v_detail;

  -- The probe must be capable of reporting a leak, or a green result
  -- means nothing. Prove the counting works by asking it the inverse
  -- question: a tenant CAN see its own rows.
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','staff','tenant_id','genalpha'))::text, true);
  set local role authenticated;
  select count(*) into n from members where tenant_id = 'genalpha';
  reset role;
  perform set_config('request.jwt.claims', null, true);
  if n = 0 then
    raise exception 'the probe reads 0 rows even for the OWN tenant — it would report ok while blind';
  end if;
  raise notice 'probe is not blind: genalpha staff still read % of their own members', n;

  if not exists (select 1 from cron.job where jobname='tenant-isolation-hourly' and active) then
    raise exception 'the hourly job was not scheduled';
  end if;
end $$;
