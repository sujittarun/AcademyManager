-- ============================================================
-- 0010 · Make SECURITY DEFINER closed by default
-- scope: shared
--
-- WHAT 0009 GOT WRONG
--
-- 0009 revoked anon EXECUTE on functions taking a `p_tenant` argument.
-- That closed the worst hole (reminder_queue, measured at 55 rows of
-- names and phone numbers to the public key) but the rule it encoded
-- was the wrong one. `p_tenant` is a naming convention, not a security
-- property. The property that matters is:
--
--     SECURITY DEFINER + executable by anon + touches tenant data
--
-- Measured with the public key after 0009 had been applied:
--
--   enrollment_fee{p_enrollment:1}              200, returns a fee
--   enrollment_payment_summary{p_enrollment:1}  200, returns money data
--   process_sync_jobs{p_limit:1}                200, DRAINED THE QUEUE
--   cron_health_check{}                         204, RAN THE HEALTH JOB
--   rls_audit{} / rpc_audit{}                   200, our own findings
--   platform_errors{p_hours:24}                 200, every tenant's errors
--
-- enrollment_fee and enrollment_payment_summary take an enrollment id
-- and no tenant, so they read across every tenant and 0009's
-- enumeration never saw them. Ids are sequential bigints.
--
-- The last three are mine, written earlier today. I wrote
-- `revoke all ... from anon` on each — and that does nothing, because
-- the grant is to PUBLIC, which is the identical mistake 0009's own
-- header calls out. Learning it in one migration and not applying it
-- three migrations earlier in the same session is exactly the failure
-- this file is meant to stop repeating.
--
-- THE RULE
--
-- Default closed. Revoke EXECUTE from PUBLIC and anon on every
-- SECURITY DEFINER function in `public`, then grant back deliberately.
-- Anything anon may call is an explicit, named, justified exception.
--
-- Trigger functions are excluded: they are invoked by the trigger
-- machinery, not by a caller, and PostgREST does not expose them.
-- ============================================================

do $$
declare
  r record;
  n_closed int := 0;
  n_staff  int := 0;
  n_svc    int := 0;

  -- Callable without a session, by design. Each justified:
  --   request_booking, submit_application — the public booking and join
  --     forms. Leo's adapter names both as anon paths.
  --   tenant_exists, tenant_publishes_timetable — evaluated INSIDE RLS
  --     policies as anon. Revoking these denies every anonymous event
  --     write and every public timetable read.
  --   sync_ingest — authenticates by tenants.api_key and derives the
  --     tenant FROM that key, so the caller cannot choose a tenant.
  public_ok text[] := array[
    'request_booking','submit_application','tenant_exists',
    'tenant_publishes_timetable','sync_ingest'];

  -- Platform internals. No client of any kind should call these; the
  -- console reaches them through platform_health, which is SECURITY
  -- DEFINER and so calls them as its owner regardless of these grants.
  service_only text[] := array[
    'process_sync_jobs','cron_health_check','rls_audit','rpc_audit',
    'events_flowing','platform_errors','propagate_block','propagate_unblock'];
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prosecdef
       and p.prorettype <> 'trigger'::regtype   -- trigger handlers are not callable
       and not (p.proname = any(public_ok))
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon',
                   r.proname, r.args);
    n_closed := n_closed + 1;

    if r.proname = any(service_only) then
      execute format('grant execute on function public.%I(%s) to service_role', r.proname, r.args);
      n_svc := n_svc + 1;
    else
      execute format('grant execute on function public.%I(%s) to authenticated, service_role',
                     r.proname, r.args);
      n_staff := n_staff + 1;
    end if;
  end loop;

  raise notice 'closed %, of which % staff-callable and % service-only', n_closed, n_staff, n_svc;
end $$;

-- ------------------------------------------------------------
-- rpc_audit(): redefined around the property that matters.
--
-- The old version filtered on the argument name `p_tenant`. It reported
-- clean while enrollment_fee, process_sync_jobs and platform_errors
-- were all open, because none of them takes that argument. A canary
-- that checks the wrong thing is worse than none — it answers "is this
-- safe?" with a confident yes.
-- ------------------------------------------------------------
-- The return type gains a column, so the old signature must go first.
-- cron_health_check references it, but only by name at runtime, so
-- dropping and recreating inside one transaction is safe.
drop function if exists public.rpc_audit();

create or replace function public.rpc_audit()
returns table (fn text, args text, touches text)
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
  with tenant_tables as (
    select c.relname::text as t
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0
     where n.nspname = 'public' and c.relkind = 'r'
  )
  select p.proname::text,
         pg_get_function_identity_arguments(p.oid),
         (select string_agg(distinct tt.t, ', ')
            from tenant_tables tt
           where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname <> all (array['request_booking','submit_application','tenant_exists',
                                 'tenant_publishes_timetable','sync_ingest'])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$$;

comment on function public.rpc_audit() is
  'SECURITY DEFINER functions anon can execute that touch tenant data. Must stay empty.';

revoke execute on function public.rpc_audit() from public, anon, authenticated;
grant execute on function public.rpc_audit() to service_role;

-- ------------------------------------------------------------
-- Assert, in the same transaction, that the doors are actually shut and
-- that the four that must stay open did stay open.
-- ------------------------------------------------------------
do $$
declare v_open text;
begin
  select string_agg(fn, ', ') into v_open from rpc_audit();
  if v_open is not null then
    raise exception 'still anon-callable after 0010: %', v_open;
  end if;

  if not has_function_privilege('anon', 'public.tenant_exists(text)', 'execute') then
    raise exception 'tenant_exists lost anon execute — anon event writes would break';
  end if;
  if not has_function_privilege('anon', 'public.tenant_publishes_timetable(text)', 'execute') then
    raise exception 'tenant_publishes_timetable lost anon execute — public timetables would break';
  end if;

  -- and that the staff path survived
  if not has_function_privilege('authenticated', 'public.record_fee_payment(text,bigint,numeric,integer,text,text,date,text,text,text,text)', 'execute') then
    raise exception 'record_fee_payment lost authenticated execute — every tenant app would break';
  end if;
  if not has_function_privilege('service_role', 'public.reminder_queue(text,date)', 'execute') then
    raise exception 'reminder_queue lost service_role execute — the reminder engine would break';
  end if;
end $$;
