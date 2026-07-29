-- ============================================================
-- 0011 · Restore anon EXECUTE on is_locked()
-- scope: shared
--
-- 0010 revoked EXECUTE from PUBLIC on every SECURITY DEFINER function.
-- is_locked() is one, and it is referenced inside RLS policy predicates
-- on centres, batches, sports, enrollments, reminder_events and others:
--
--   batches_staff_w: ((auth_role()='staff' AND ...) OR (NOT is_locked()))
--
-- Policies for the `public` role apply to anon too, and a policy
-- predicate is evaluated AS THE CALLING ROLE. With no EXECUTE, anon did
-- not get `false` — it got an error, and the whole read failed:
--
--   GET /rest/v1/centres?tenant_id=eq.raj
--     -> 42501 permission denied for function is_locked
--
-- which took Raj's public timetable down for the second time today.
--
-- Granting this back discloses nothing: is_locked() reads one row of
-- platform_settings and returns a boolean about the platform's own
-- lockdown state. It says nothing about any tenant.
--
-- THE RULE THIS MAKES EXPLICIT
--
-- Any function named in an RLS policy predicate must be executable by
-- every role that policy applies to — including anon. 0003 taught this
-- with an inlined subquery, 0007 taught it again with tenants, and 0010
-- managed to teach it a third way, through a grant instead of a
-- predicate. So the check now lives in code, not in my memory:
-- policy_fn_audit() lists any function used in a policy that anon
-- cannot execute, and cron_health_check reports it hourly.
--
-- My own probe hid this for several minutes. It counted
-- len(json_response) and a PostgREST error body is a 4-key object, so
-- "4 rows" was really "4 error fields". A check that cannot tell an
-- error from data is not a check. Assert on content, not on length.
-- ============================================================

grant execute on function public.is_locked() to public;

-- ------------------------------------------------------------
-- policy_fn_audit(): the missing shape check.
-- ------------------------------------------------------------
create or replace function public.policy_fn_audit()
returns table (fn text, used_by text)
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
  with pol as (
    select tablename::text as tbl, policyname::text as pol,
           coalesce(qual,'') || ' ' || coalesce(with_check,'') as pred
      from pg_policies where schemaname = 'public'
  )
  select p.proname::text,
         (select string_agg(distinct pol.tbl || '.' || pol.pol, ', ')
            from pol where pol.pred ~* ('\m' || p.proname || '\M'))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prorettype <> 'trigger'::regtype
     and not has_function_privilege('anon', p.oid, 'execute')
     and exists (select 1 from pol where pol.pred ~* ('\m' || p.proname || '\M'))
   order by 1
$$;

comment on function public.policy_fn_audit() is
  'Functions named in an RLS policy that anon cannot execute. Any row here means silent denial.';

revoke execute on function public.policy_fn_audit() from public, anon, authenticated;
grant execute on function public.policy_fn_audit() to service_role;

-- ------------------------------------------------------------
-- Hourly. Body is 0009's verbatim with one block appended.
-- ------------------------------------------------------------
create or replace function public.cron_health_check()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_gaps int; v_failed int; v_unscoped int; v_errs int; v_tenants text; v_rpc int; v_polfn int;
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

  select count(*) into v_unscoped from rls_audit();
  if v_unscoped > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rls_audit','error',
        v_unscoped||' anon policy/policies with no tenant filter: '||
        (select string_agg(tbl||'.'||policy_name, ', ') from rls_audit()));
  end if;

  select count(*), string_agg(distinct tenant_id, ', ')
    into v_errs, v_tenants
    from platform_errors(1);
  if v_errs > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','client_errors','warn',
        v_errs||' distinct client error(s) in the last hour: '||coalesce(v_tenants,'?'));
  end if;

  if not events_flowing() then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','events_sink','error',
        'no events for 12h despite traffic in the past week — anon writes are likely broken');
  end if;

  select count(*) into v_rpc from rpc_audit();
  if v_rpc > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rpc_audit','error',
        v_rpc||' definer function(s) executable by anon: '||
        (select string_agg(fn, ', ') from rpc_audit()));
  end if;

  -- appended by 0011: a policy that will silently deny because anon
  -- cannot execute a function its predicate calls
  select count(*) into v_polfn from policy_fn_audit();
  if v_polfn > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','policy_fn_audit','error',
        v_polfn||' policy function(s) anon cannot execute: '||
        (select string_agg(fn||' ('||used_by||')', ', ') from policy_fn_audit()));
  end if;
end $function$;

do $$
begin
  if exists (select 1 from policy_fn_audit()) then
    raise exception 'a policy still calls a function anon cannot execute: %',
      (select string_agg(fn, ', ') from policy_fn_audit());
  end if;
end $$;
