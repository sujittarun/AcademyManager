-- ============================================================
-- 0041 · Remove the Remembering App's leftovers, with consent
-- scope: shared
--
-- `memories` and `push_subscriptions` were never Academy Manager
-- tables. They belonged to a family side project that shared this
-- Supabase project when the free-project quota ran out. That app moved
-- to Deno KV months ago — its own server says so — so what remained
-- here was the residue of a retired integration:
--
--   memories                          2 rows
--   push_subscriptions                0 rows
--   send-due-reminders (function)     ACTIVE, notifying nobody
--   send-due-reminders-every-minute   firing ~43,000 times a month
--
-- 0033 sealed them, 0035 watched them, 0036 labelled them and
-- PLATFORM.md carved out a rule for them. That is four pieces of
-- platform machinery spent on two rows that belong to a child's
-- reminders app. The owner asked for them to be gone so the business
-- database holds only the business.
--
-- The rows were exported first, to
-- "Suhas - Remembering App/supabase-leftover-export-2026-08-01.json",
-- which is now the only copy. Removal was explicitly authorised on
-- 2026-08-01; it is not a cleanup someone decided on their own.
-- ============================================================

-- 1. Stop the every-minute job before removing what it reads.
do $$
begin
  perform cron.unschedule('send-due-reminders-every-minute');
exception when others then
  raise notice 'cron job already gone: %', sqlerrm;
end $$;

-- 2. The tables themselves.
drop table if exists public.memories;
drop table if exists public.push_subscriptions;

-- 3. The probe no longer needs to prove they stay sealed — there is
--    nothing left to seal. Everything else in anon_probe() is
--    unchanged, including the per-tenant timetable sweep.
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

  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  begin
    select count(*) into v_n from reminder_queue(v_tenant);
    return query select 'reminder_queue as anon'::text, 'LEAK'::text,
                        v_n || ' rows of member names and phones'::text;
  exception when others then
    return query select 'reminder_queue as anon'::text, 'ok'::text, sqlerrm;
  end;

  begin
    perform enrollment_fee((select id from enrollments where tenant_id = v_tenant limit 1));
    return query select 'enrollment_fee as anon'::text, 'LEAK'::text, 'returned a fee'::text;
  exception when others then
    return query select 'enrollment_fee as anon'::text, 'ok'::text, sqlerrm;
  end;

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

  for i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    begin
      select count(*) into v_c from centres where tenant_id = v_ids[i];
      select count(*) into v_b from batches where tenant_id = v_ids[i];
      select count(*) into v_s from sports  where tenant_id = v_ids[i];
    exception when others then
      v_c := 0; v_b := 0; v_s := 0;
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
  'Calls the dangerous endpoints AS anon and reports any that answer, plus every tenant''s timetable scope in both directions. Behaviour, not shape.';

revoke execute on function public.anon_probe() from public, anon, authenticated;
grant execute on function public.anon_probe() to service_role;

-- ------------------------------------------------------------
-- Verify: the tables are gone, the job is gone, and the platform is
-- exactly as healthy as it was a minute ago.
-- ------------------------------------------------------------
do $$
declare v_leaks text; v_broken text; v_rows int;
begin
  if to_regclass('public.memories') is not null
     or to_regclass('public.push_subscriptions') is not null then
    raise exception 'a leftover table is still present';
  end if;
  if exists (select 1 from cron.job where jobname = 'send-due-reminders-every-minute') then
    raise exception 'the every-minute job is still scheduled';
  end if;

  select count(*) into v_rows from anon_probe();
  if v_rows < 10 then
    raise exception 'probe returned only % rows — the per-tenant sweep is not running', v_rows;
  end if;
  select string_agg(check_name, ', ') into v_leaks  from anon_probe() where verdict = 'LEAK';
  select string_agg(check_name, ', ') into v_broken from anon_probe() where verdict = 'BROKEN';
  if v_leaks  is not null then raise exception 'anon can reach: %', v_leaks; end if;
  if v_broken is not null then raise exception 'public path broken: %', v_broken; end if;

  raise notice 'leftovers removed; probe clean across % checks', v_rows;
end $$;
