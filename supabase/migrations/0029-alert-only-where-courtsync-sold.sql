-- ============================================================
-- 0029 · Alert on channel sync only where CourtSync is sold
-- scope: shared
--
-- Insight was reporting "3 integrations stale" for Leo. CourtSync is
-- the channel manager — Playo, Hudle, District, the venue's own site
-- and the front desk on one availability board — and it is an optional
-- module, sold separately, gated on config.modules.booking.
--
-- No tenant has it switched on. Leo's three integration rows are
-- leftovers from a demo: the venue ids are leo-playo-demo and friends,
-- and 215 of Leo's 231 bookings were inserted in one go on 4 July.
--
-- So the console was nagging the operator about a module nobody had
-- bought, for a connection that never existed. AcademyManager's own
-- brief says it stays account-level — MRR, GMV, adoption, growth — and
-- that operational data stays in each tenant's app. A stale partner
-- connection is operational, and it belongs on CourtSync's board.
--
-- The platform still PERFORMS the sync: the keys are in vault.secrets
-- and a booking made at 2am must not double-sell a court. Performing it
-- and reporting it to the portfolio view are different questions, and
-- the previous filter answered only the first.
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
        -- Only for a tenant that has actually bought the booking
        -- module. CourtSync owns channel sync; this console is
        -- account-level — MRR, adoption, growth — and a Playo
        -- connection nobody has bought is not an account-level fact.
        and coalesce((select (t.config #>> '{modules,booking}')::boolean
                        from tenants t where t.id = i.tenant_id), false)
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
  if n <> 0 then
    raise exception 'expected no stale-integration alerts (no tenant has booking on), got %', n;
  end if;

  raise notice 'stale integration alerts: 0 — none of the tenants has bought CourtSync';
end $$;
