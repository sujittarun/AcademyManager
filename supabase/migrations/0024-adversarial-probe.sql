-- ============================================================
-- 0024 · Attack ourselves, hourly
-- scope: shared
--
-- Every real leak found today was found the same way: curling a live
-- endpoint with the public anon key and reading what came back. Not one
-- of them was found by reading SQL, and `rls_audit()` — a shape check —
-- passed cleanly through the worst of them, because shape cannot see
-- behaviour.
--
--   reminder_queue{p_tenant:"raj"}   ->  200, 55 rows of names and
--                                        parents' phone numbers
--   enrollment_fee{p_enrollment:1}   ->  200, another tenant's fee
--   process_sync_jobs{p_limit:1}     ->  200, drained the queue
--
-- All three were reachable by anyone with the key that ships in six
-- public repositories, and all three would have looked fine in a code
-- review.
--
-- So this does what I did by hand, on a schedule: it actually calls the
-- dangerous endpoints as `anon` and fails loudly if any of them answers.
-- A probe that exercises the real path is the only kind that could have
-- caught these.
--
-- It runs INSIDE Postgres, becoming anon with SET ROLE, rather than over
-- HTTP. Same grants, same policies, no key in a cron job and no
-- outbound request to be blocked. What it cannot see is PostgREST's own
-- layer — for that, exercise the real URL after any migration touching a
-- policy or a grant.
--
-- Deliberately SECURITY INVOKER: Postgres forbids SET ROLE inside a
-- definer function, and rightly — a definer that can change role is a
-- privilege ladder. So the probe runs as whoever calls it, and only
-- postgres (via cron) can call it usefully.
-- ============================================================

create or replace function public.anon_probe()
returns table (check_name text, verdict text, detail text)
language plpgsql
set search_path to 'public'
as $function$
declare
  v_n     int;
  v_tenant text;
begin
  -- A tenant with real rows, so "0 rows" means denied rather than empty.
  select t.id into v_tenant
    from tenants t
   where exists (select 1 from members m where m.tenant_id = t.id)
   order by (select count(*) from members m where m.tenant_id = t.id) desc
   limit 1;

  if v_tenant is null then
    return query select 'setup'::text, 'skipped'::text,
                        'no tenant has members; nothing to probe'::text;
    return;
  end if;

  -- Become anon for the duration. local, so it unwinds with the
  -- transaction however this exits.
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  -- 1 ── the one that actually leaked
  begin
    select count(*) into v_n from reminder_queue(v_tenant);
    return query select 'reminder_queue as anon'::text, 'LEAK'::text,
                        v_n || ' rows of member names and phones'::text;
  exception when others then
    return query select 'reminder_queue as anon'::text, 'ok'::text, sqlerrm;
  end;

  -- 2 ── money data with no p_tenant, which the first fix missed
  begin
    perform enrollment_fee((select id from enrollments where tenant_id = v_tenant limit 1));
    return query select 'enrollment_fee as anon'::text, 'LEAK'::text, 'returned a fee'::text;
  exception when others then
    return query select 'enrollment_fee as anon'::text, 'ok'::text, sqlerrm;
  end;

  -- 3 ── platform operations
  begin
    perform process_sync_jobs(1);
    return query select 'process_sync_jobs as anon'::text, 'LEAK'::text, 'ran the queue'::text;
  exception when others then
    return query select 'process_sync_jobs as anon'::text, 'ok'::text, sqlerrm;
  end;

  begin
    perform platform_errors(1);
    return query select 'platform_errors as anon'::text, 'LEAK'::text, 'returned errors'::text;
  exception when others then
    return query select 'platform_errors as anon'::text, 'ok'::text, sqlerrm;
  end;

  -- 4 ── the tables themselves. RLS held all day; this is the control
  --      that proves the probe would notice if it stopped holding.
  begin
    select count(*) into v_n from members;
    return query select 'members table as anon'::text,
                        case when v_n = 0 then 'ok' else 'LEAK' end,
                        v_n || ' rows'::text;
  exception when others then
    return query select 'members table as anon'::text, 'ok'::text, sqlerrm;
  end;

  begin
    select count(*) into v_n from payments;
    return query select 'payments table as anon'::text,
                        case when v_n = 0 then 'ok' else 'LEAK' end,
                        v_n || ' rows'::text;
  exception when others then
    return query select 'payments table as anon'::text, 'ok'::text, sqlerrm;
  end;

  -- 5 ── and the paths that MUST still work, because a probe that only
  --      checks for leaks will happily report a healthy system after
  --      you have locked out every real user.
  begin
    if not tenant_exists(v_tenant) then
      return query select 'tenant_exists (must work)'::text, 'BROKEN'::text,
                          'returned false for a real tenant'::text;
    else
      return query select 'tenant_exists (must work)'::text, 'ok'::text, ''::text;
    end if;
  exception when others then
    return query select 'tenant_exists (must work)'::text, 'BROKEN'::text, sqlerrm;
  end;

  begin
    perform tenant_publishes_timetable(v_tenant);
    return query select 'tenant_publishes_timetable (must work)'::text, 'ok'::text, ''::text;
  exception when others then
    return query select 'tenant_publishes_timetable (must work)'::text, 'BROKEN'::text, sqlerrm;
  end;

  reset role;
end $function$;

comment on function public.anon_probe() is
  'Calls the dangerous endpoints AS anon and reports any that answer. Behaviour, not shape.';

revoke execute on function public.anon_probe() from public, anon, authenticated;
grant execute on function public.anon_probe() to service_role;

-- ------------------------------------------------------------
-- Its own hourly job, because cron_health_check is SECURITY DEFINER and
-- so cannot switch role either. cron runs as postgres, which can.
-- ------------------------------------------------------------
create or replace function public.cron_anon_probe()
returns void
language plpgsql
set search_path to 'public'
as $function$
declare v_leaks text; v_broken text;
begin
  select string_agg(check_name, ', ') into v_leaks  from anon_probe() where verdict = 'LEAK';
  select string_agg(check_name, ', ') into v_broken from anon_probe() where verdict = 'BROKEN';

  if v_leaks is not null then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','anon_probe','error', 'ANON CAN REACH: '||v_leaks);
  end if;

  -- The other direction matters just as much. A probe that only hunts
  -- leaks will report a healthy system on the morning you have locked
  -- every real user out — which is how the timetable went down twice.
  if v_broken is not null then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','anon_probe','error', 'PUBLIC PATH BROKEN: '||v_broken);
  end if;
end $function$;

revoke execute on function public.cron_anon_probe() from public, anon, authenticated;

select cron.schedule('anon-probe-hourly', '17 * * * *', $cron$select public.cron_anon_probe()$cron$);

-- ------------------------------------------------------------
-- Run it now. If the probe finds a leak today, this migration fails and
-- nothing is recorded — which is the correct outcome.
-- ------------------------------------------------------------
do $$
declare v_leaks text; v_broken text; v_rows int;
begin
  select count(*) into v_rows from anon_probe();
  if v_rows = 0 then raise exception 'probe returned nothing — it is not testing anything'; end if;

  select string_agg(check_name, ', ') into v_leaks   from anon_probe() where verdict = 'LEAK';
  select string_agg(check_name, ', ') into v_broken  from anon_probe() where verdict = 'BROKEN';

  if v_leaks  is not null then raise exception 'anon can still reach: %', v_leaks; end if;
  if v_broken is not null then raise exception 'public path broken: %', v_broken; end if;

  raise notice 'anon_probe: % checks, no leaks, public paths intact', v_rows;
end $$;
