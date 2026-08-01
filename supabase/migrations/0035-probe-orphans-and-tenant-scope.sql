-- ============================================================
-- 0035 · anon_probe() v2 — orphan tables + every tenant's scope, hourly
-- scope: shared
--
-- 0033 closed two orphan tables that sat open for weeks while every
-- audit read green. The lesson is not "close those two tables"; it is
-- that the probe only attacked the endpoints we already knew about.
-- This extends it in two directions:
--
--   1. The orphan tables themselves — prove they STAY closed, including
--      the write path (the insert is attempted and rolled back inside a
--      subtransaction, so the probe never leaves residue).
--
--   2. Every tenant, not just the busiest one. For each tenant the probe
--      snapshots what anon SHOULD see of centres/batches/sports —
--      everything if config.features.publicTimetable, nothing otherwise
--      — before dropping to anon, then compares against what anon
--      actually sees. Content, not length: a publisher's counts must
--      match exactly (today that is raj at 5/14/5, but the expectation
--      is computed live, so adding a centre does not break the probe);
--      a private tenant must show zero. Both directions alarm: LEAK for
--      a private tenant exposed, BROKEN for a publisher gone dark —
--      the second timetable outage would have been caught by this row.
--
-- Everything from 0024 is retained verbatim. Same hourly cron job
-- (cron_anon_probe) picks this up — no new schedule needed.
-- ============================================================

create or replace function public.anon_probe()
returns table (check_name text, verdict text, detail text)
language plpgsql
set search_path to 'public'
as $function$
declare
  v_n      int;
  v_tenant text;
  v_ids text[]; v_pub boolean[]; v_nc int[]; v_nb int[]; v_ns int[];
  i    int;
  v_c  int; v_b int; v_s int;
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

  -- Snapshot per-tenant timetable expectations BEFORE dropping to anon:
  -- publishers should show anon everything, private tenants nothing.
  select array_agg(x.id order by x.id),
         array_agg(x.pub order by x.id),
         array_agg(x.nc  order by x.id),
         array_agg(x.nb  order by x.id),
         array_agg(x.ns  order by x.id)
    into v_ids, v_pub, v_nc, v_nb, v_ns
    from (
      select t.id,
             coalesce((t.config #>> '{features,publicTimetable}') = 'true', false) as pub,
             (select count(*) from centres c where c.tenant_id = t.id)::int as nc,
             (select count(*) from batches b where b.tenant_id = t.id)::int as nb,
             (select count(*) from sports s  where s.tenant_id = t.id)::int as ns
        from tenants t
    ) x;

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

  -- 5 ── the orphan app tables 0033 closed. Read AND write paths: the
  --      insert attempt lives in a subtransaction and is rolled back by
  --      the raise, so a leak is detected without leaving residue.
  begin
    execute 'select count(*) from public.memories' into v_n;
    return query select 'memories table as anon'::text,
                        case when v_n = 0 then 'ok' else 'LEAK' end,
                        v_n || ' rows'::text;
  exception when others then
    return query select 'memories table as anon'::text, 'ok'::text, sqlerrm;
  end;

  begin
    execute $probe$insert into public.push_subscriptions (endpoint, p256dh, auth)
      values ('probe://denied', 'x', 'y')$probe$;
    raise exception using errcode = 'PR001', message = 'probe insert landed';
  exception
    when sqlstate 'PR001' then
      return query select 'push_subscriptions insert as anon'::text, 'LEAK'::text,
                          'anon insert succeeded (rolled back by probe)'::text;
    when others then
      return query select 'push_subscriptions insert as anon'::text, 'ok'::text, sqlerrm;
  end;

  -- 6 ── every tenant's timetable scope, both directions
  for i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    begin
      select count(*) into v_c from centres where tenant_id = v_ids[i];
      select count(*) into v_b from batches where tenant_id = v_ids[i];
      select count(*) into v_s from sports  where tenant_id = v_ids[i];
    exception when others then
      v_c := 0; v_b := 0; v_s := 0;   -- read denied outright = nothing visible
    end;

    if v_pub[i] then
      if v_c = v_nc[i] and v_b = v_nb[i] and v_s = v_ns[i] then
        return query select ('timetable scope: ' || v_ids[i])::text, 'ok'::text,
                            format('publisher, anon sees %s/%s/%s as expected', v_c, v_b, v_s);
      else
        return query select ('timetable scope: ' || v_ids[i])::text, 'BROKEN'::text,
                            format('publisher, anon sees %s/%s/%s but %s/%s/%s exist',
                                   v_c, v_b, v_s, v_nc[i], v_nb[i], v_ns[i]);
      end if;
    else
      if v_c = 0 and v_b = 0 and v_s = 0 then
        return query select ('timetable scope: ' || v_ids[i])::text, 'ok'::text,
                            'private, anon sees nothing'::text;
      else
        return query select ('timetable scope: ' || v_ids[i])::text, 'LEAK'::text,
                            format('private tenant, anon sees %s centres / %s batches / %s sports',
                                   v_c, v_b, v_s);
      end if;
    end if;
  end loop;

  -- 7 ── and the paths that MUST still work, because a probe that only
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
  'Calls the dangerous endpoints AS anon and reports any that answer — now including the closed orphan tables and every tenant''s timetable scope, both directions. Behaviour, not shape.';

revoke execute on function public.anon_probe() from public, anon, authenticated;
grant execute on function public.anon_probe() to service_role;

-- ------------------------------------------------------------
-- Run it now. If the extended probe finds a leak or a broken public
-- path today, this migration fails and nothing is recorded.
-- ------------------------------------------------------------
do $$
declare v_leaks text; v_broken text; v_rows int;
begin
  select count(*) into v_rows from anon_probe();
  if v_rows < 10 then
    raise exception 'probe returned only % rows — the per-tenant sweep is not running', v_rows;
  end if;

  select string_agg(check_name, ', ') into v_leaks  from anon_probe() where verdict = 'LEAK';
  select string_agg(check_name, ', ') into v_broken from anon_probe() where verdict = 'BROKEN';

  if v_leaks  is not null then raise exception 'anon can still reach: %', v_leaks; end if;
  if v_broken is not null then raise exception 'public path broken: %', v_broken; end if;

  raise notice 'anon_probe v2: % checks, no leaks, public paths intact, all tenants swept', v_rows;
end $$;
