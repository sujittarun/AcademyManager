-- ============================================================
-- 0009 · Stop anon calling tenant functions
-- scope: shared
--
-- THE PROBLEM — live, not latent
--
-- 40 functions take a `p_tenant` argument. 33 of them were executable
-- by `anon`, are SECURITY DEFINER, and check nothing about the caller.
-- SECURITY DEFINER means they run as the owner and RLS does not apply.
-- So the tenant to operate on was whatever the caller typed.
--
-- The anon key is public by design and is committed in six public
-- repositories. Measured with that key, no session, from outside:
--
--   POST /rest/v1/rpc/reminder_queue  {"p_tenant":"raj"}
--     -> HTTP 200, 55 rows
--
-- reminder_queue returns member_name, parent_name, phone, due_date and
-- amount. So every family's name, guardian and phone number at any
-- tenant was readable by anyone who viewed source on a public page. The
-- same key could also call record_fee_payment, void_payment and
-- confirm_payment against any tenant — writing and reversing payments.
--
-- RLS was doing its job the whole time: the direct table read returns 0
-- rows with the same key. The functions went around it.
--
-- Leo's own cloud adapter states the intended invariant at the top of
-- the file:
--
--   "anon key (public pages): public_slots view, request_booking RPC,
--    applications + events inserts — nothing with PII is readable."
--
-- That is the correct design. It simply was not enforced. This restores
-- it rather than changing it.
--
-- THE FIX
--
-- Revoke EXECUTE from anon on every p_tenant function except the four
-- that genuinely need it. Done by enumeration rather than a list, so a
-- function added later is caught too — the default becomes closed.
--
-- What this does NOT fix: a signed-in staff member of tenant A can
-- still pass p_tenant='B'. That needs assert_staff_or_service(p_tenant)
-- inside each body — the helper already exists and is already used by
-- tenant_health and six others. It is deliberately a separate change:
-- it edits 33 function bodies, several over 100 lines, and doing that
-- carelessly at the end of a long session is how the Raj outage
-- happened. Today all five staff logins belong to one person, so the
-- exposure is to nobody; the anon hole was to everybody.
-- ============================================================

do $$
declare
  r record;
  n int := 0;
  -- Anon must keep these four:
  --   request_booking, submit_application — the public booking and join
  --     forms; Leo's adapter names both as anon paths by design.
  --   tenant_exists, tenant_publishes_timetable — evaluated INSIDE RLS
  --     policies as anon. Revoking these would deny every anonymous
  --     event write and every public timetable read.
  keep text[] := array['request_booking','submit_application',
                       'tenant_exists','tenant_publishes_timetable'];
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n2 on n2.oid = p.pronamespace
     where n2.nspname = 'public'
       and pg_get_function_identity_arguments(p.oid) ilike '%p_tenant%'
       and not (p.proname = any(keep))
       and has_function_privilege('anon', p.oid, 'execute')
  loop
    -- Revoke from PUBLIC as well as anon. The grant that actually
    -- carried this was to PUBLIC — visible in the ACL as a bare
    -- "=X/postgres" — and anon inherits it. Revoking anon alone changes
    -- nothing, which the dry run caught by still finding all 36 open.
    execute format('revoke execute on function public.%I(%s) from public, anon', r.proname, r.args);
    -- Grant back explicitly to the roles that should have it, so a
    -- function whose ONLY grant was the PUBLIC one does not lose the
    -- staff app along with anon.
    execute format('grant execute on function public.%I(%s) to authenticated, service_role',
                   r.proname, r.args);
    n := n + 1;
  end loop;
  raise notice 'revoked anon execute on % function(s)', n;
end $$;

-- ------------------------------------------------------------
-- Prove it in the same transaction, and keep proving it hourly.
-- ------------------------------------------------------------
do $$
declare v_open text;
begin
  select string_agg(p.proname, ', ')
    into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_function_identity_arguments(p.oid) ilike '%p_tenant%'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname <> all (array['request_booking','submit_application',
                                 'tenant_exists','tenant_publishes_timetable']);
  if v_open is not null then
    raise exception 'still anon-callable: %', v_open;
  end if;

  -- and the four that must stay
  if not has_function_privilege('anon', 'public.tenant_exists(text)', 'execute') then
    raise exception 'tenant_exists lost anon execute — anon event writes would break';
  end if;
  if not has_function_privilege('anon', 'public.tenant_publishes_timetable(text)', 'execute') then
    raise exception 'tenant_publishes_timetable lost anon execute — public timetables would break';
  end if;
end $$;

-- ------------------------------------------------------------
-- rpc_audit(): the shape check for this class.
--
-- rls_audit() covers policies. Nothing covered function grants, which
-- is why this survived. A tenant-scoped function anon can call is now a
-- reportable finding by definition.
-- ------------------------------------------------------------
create or replace function public.rpc_audit()
returns table (fn text, args text)
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
  select p.proname::text, pg_get_function_identity_arguments(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_function_identity_arguments(p.oid) ilike '%p_tenant%'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname <> all (array['request_booking','submit_application',
                                 'tenant_exists','tenant_publishes_timetable'])
   order by 1
$$;

comment on function public.rpc_audit() is
  'Tenant-scoped functions anon can execute. Must stay empty except the four public-by-design.';

revoke all on function public.rpc_audit() from anon, authenticated;
grant execute on function public.rpc_audit() to service_role;

-- ------------------------------------------------------------
-- Wire into the hourly job. Body is 0007's verbatim, appended to.
-- ------------------------------------------------------------
create or replace function public.cron_health_check()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_gaps int; v_failed int; v_unscoped int; v_errs int; v_tenants text; v_rpc int;
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

  -- appended by 0009: a tenant-scoped function anon can call
  select count(*) into v_rpc from rpc_audit();
  if v_rpc > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rpc_audit','error',
        v_rpc||' tenant function(s) executable by anon: '||
        (select string_agg(fn, ', ') from rpc_audit()));
  end if;
end $function$;

-- ------------------------------------------------------------
-- Surface it in the console alongside the RLS check.
-- Body is 0005's verbatim with one key appended.
-- ------------------------------------------------------------
create or replace function public.platform_health()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select jsonb_build_object(
    'as_of', now(),
    'jobs', jsonb_build_object(
      'pending', (select count(*) from sync_jobs where status = 'pending'),
      'failed',  (select count(*) from sync_jobs where status = 'failed'),
      'oldest_pending_mins',
        (select coalesce(round(extract(epoch from (now() - min(created_at))) / 60), 0)::int
           from sync_jobs where status = 'pending')
    ),
    'stale_integrations', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tenant_id', tenant_id, 'channel', channel,
        'last_sync_at', last_sync_at, 'last_result', last_result)), '[]'::jsonb)
      from integrations
      where enabled and (last_sync_at is null or last_sync_at < now() - interval '6 hours')
    ),
    'dead_letters', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'tenant_id', tenant_id, 'channel', channel,
        'action', action, 'attempts', attempts, 'last_error', last_error)), '[]'::jsonb)
      from sync_jobs where status = 'failed'
    ),
    -- appended by 0005
    'client_errors_24h', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tenant_id', tenant_id, 'msg', msg, 'ver', ver,
        'occurrences', occurrences, 'sessions', affected_sessions,
        'last_seen', last_seen, 'page', sample_page)), '[]'::jsonb)
      from platform_errors(24)
    ),
    'rls_unscoped', (
      select coalesce(jsonb_agg(tbl || '.' || policy_name), '[]'::jsonb)
      from rls_audit()
    ),
    -- appended by 0009
    'rpc_anon_callable', (
      select coalesce(jsonb_agg(fn), '[]'::jsonb) from rpc_audit()
    )
  ) into result;
  return result;
end $function$;
