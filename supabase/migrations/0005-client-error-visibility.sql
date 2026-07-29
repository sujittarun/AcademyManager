-- ============================================================
-- 0005 · Make a tenant's client errors visible from Academy Manager
-- scope: shared
--
-- The pipe already exists and already works: `events` has 1401 rows, and
-- 21 of them are name='client_error' (19 leo, 2 matchpoint), each
-- carrying msg, src, stack, ua, ver and role in props. Nothing has ever
-- read them. A tenant's app can throw on a parent's phone and the owner
-- has no way to know.
--
-- The gap is therefore not collection — it is surfacing. Two functions,
-- no new table, no new screen, and the logs stay in Postgres exactly as
-- the owner asked.
--
-- Grouping happens in SQL, not in the console, per the house rule: one
-- definition of "how many distinct errors does Leo have today", shared by
-- whatever reads it.
-- ============================================================

-- ------------------------------------------------------------
-- platform_errors(): distinct client errors, newest first.
--
-- Grouped on (tenant, first 90 chars of message, app version) so a
-- hundred repeats of one bug read as one row with a count, which is what
-- makes this glanceable rather than a log wall.
-- ------------------------------------------------------------
create or replace function public.platform_errors(p_hours int default 24)
returns table (
  tenant_id   text,
  msg         text,
  ver         text,
  occurrences bigint,
  affected_sessions bigint,
  first_seen  timestamptz,
  last_seen   timestamptz,
  sample_page text,
  sample_src  text
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select e.tenant_id,
         left(coalesce(e.props ->> 'msg', '(no message)'), 90) as msg,
         coalesce(e.props ->> 'ver', '?')                      as ver,
         count(*)                                              as occurrences,
         count(distinct e.session_id)                          as affected_sessions,
         min(e.at)                                             as first_seen,
         max(e.at)                                             as last_seen,
         (array_agg(e.page order by e.at desc))[1]             as sample_page,
         (array_agg(e.props ->> 'src' order by e.at desc))[1]  as sample_src
    from events e
   where e.name = 'client_error'
     and e.at > now() - make_interval(hours => greatest(p_hours, 1))
   group by 1, 2, 3
   order by max(e.at) desc
$$;

comment on function public.platform_errors(int) is
  'Distinct client-side errors per tenant in the last N hours, newest first.';

revoke all on function public.platform_errors(int) from anon;
grant execute on function public.platform_errors(int) to authenticated, service_role;

-- ------------------------------------------------------------
-- platform_health(): body below is the live definition verbatim, with
-- two keys appended. Nothing existing is altered.
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
    )
  ) into result;
  return result;
end $function$;

-- ------------------------------------------------------------
-- And log a spike hourly, so it reaches the owner without him going to
-- look. Body is 0003's verbatim, with the error count appended.
-- ------------------------------------------------------------
create or replace function public.cron_health_check()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_gaps int; v_failed int; v_unscoped int; v_errs int; v_tenants text;
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
end $function$;
