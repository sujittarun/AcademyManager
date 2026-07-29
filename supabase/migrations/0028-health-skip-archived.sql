-- ============================================================
-- 0028 · Stop alerting on tenants that are not in the console
-- scope: shared
--
-- Insight said "7 integrations stale". Four of them were machaxi's and
-- matchpoint's — both archived hours earlier, both absent from the
-- console. An alert you cannot click through to is not an alert, it is
-- a number that trains you to ignore the strip.
--
-- The remaining three are Leo's, and they are real: District, Hudle and
-- Playo last synced on 2026-07-05. Those stay.
--
-- Same filter on dead_letters, for the same reason.
-- ============================================================

create or replace function public.platform_health()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'tenant_id', i.tenant_id, 'channel', i.channel,
        'last_sync_at', i.last_sync_at, 'last_result', i.last_result)), '[]'::jsonb)
      from integrations i
      where i.enabled
        and (i.last_sync_at is null or i.last_sync_at < now() - interval '6 hours')
        -- An archived tenant is not in the console, so an alert about
        -- its feeds is a number nobody can act on. Four of the seven
        -- "stale integrations" belonged to machaxi and matchpoint,
        -- archived hours earlier.
        and not coalesce((select (t.config->>'archived')::boolean
                            from tenants t where t.id = i.tenant_id), false)
    ),
    'dead_letters', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', sj.id, 'tenant_id', sj.tenant_id, 'channel', sj.channel,
        'action', sj.action, 'attempts', sj.attempts, 'last_error', sj.last_error)), '[]'::jsonb)
      from sync_jobs sj where sj.status = 'failed'
        and not coalesce((select (t.config->>'archived')::boolean
                            from tenants t where t.id = sj.tenant_id), false)
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
end $function$
;

do $$
declare v jsonb; n int;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);
  v := platform_health();

  select count(*) into n from jsonb_array_elements(v->'stale_integrations');
  if n <> 3 then
    raise exception 'expected 3 stale integrations (leo only), got %', n;
  end if;

  if exists (
    select 1 from jsonb_array_elements(v->'stale_integrations') x
     where x->>'tenant_id' in ('machaxi','matchpoint')
  ) then
    raise exception 'an archived tenant is still being alerted on';
  end if;

  raise notice 'stale integrations now: 3, all leo';
end $$;
