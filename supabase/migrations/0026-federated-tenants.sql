-- ============================================================
-- 0026 · Federated tenants: report in without moving in
-- scope: shared
--
-- GenAlpha predates this platform. It is live, has real families
-- depending on it, keeps its records in its own Supabase project, and
-- has nineteen tables of a schema built for a different model. Merging
-- it would mean migrating live data and rewriting a working app for no
-- benefit the owner would ever see.
--
-- So it does not move. It reports.
--
-- The console already derives a tenant's status from `events`, which
-- anon may write for any registered tenant. A rollup is just another
-- event — name 'tenant_rollup', counts in props — so this needs no new
-- table, no new secret, and no new endpoint. A federated tenant posts
-- one a day and the console shows real numbers instead of zeros.
--
-- Same trust level as page_view: anyone holding the public key could
-- forge one. That is acceptable for aggregate counts on a dashboard,
-- and it is why the rollup carries NO personal data — counts and
-- totals only, never a name or a number.
--
-- Falls back only when the native tables are empty, so a tenant that
-- lives here is unaffected.
-- ============================================================

create or replace function public.operator_portfolio()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select coalesce(jsonb_agg(obj order by ord), '[]'::jsonb) into result from (
    select t.created_at as ord, jsonb_build_object(
      'tenant_id', t.id, 'name', t.name, 'config', t.config,
      'plan', s.plan, 'mrr', coalesce(s.mrr,0), 'sub_status', s.status, 'renews_on', s.renews_on,
      'tier', s.tier, 'player_cap', s.player_cap, 'msg_rate', coalesce(s.msg_rate,0.35),
      -- A federated tenant keeps its records in its own Supabase project,
      -- so members/payments here are empty for it. It reports totals as a
      -- `tenant_rollup` event instead; fall back to the newest one rather
      -- than showing an academy with no students.
      'active_players', coalesce(
        nullif((select count(*) from members m where m.tenant_id=t.id and m.status in ('active','due')), 0),
        (select (e.props->>'players')::int from events e
          where e.tenant_id=t.id and e.name='tenant_rollup'
          order by e.at desc limit 1),
        0),
      'contacts_count', (select count(distinct regexp_replace(phone,'\D','','g')) from bookings b
                         where b.tenant_id=t.id and b.phone is not null
                           and length(regexp_replace(b.phone,'\D','','g'))>=10 and b.status<>'cancelled'),
      'total_bookings', (select count(*) from bookings b where b.tenant_id=t.id and b.status<>'cancelled'),
      'weekend_bookings', (select count(*) from bookings b where b.tenant_id=t.id and b.status<>'cancelled' and extract(isodow from b.date)>=6),
      'weekday_bookings', (select count(*) from bookings b where b.tenant_id=t.id and b.status<>'cancelled' and extract(isodow from b.date)<6),
      'booker_rev_90d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date>=current_date-90),
      'msgs_30d', (select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30),
      'msg_cost_30d', round((select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30) * coalesce(s.msg_rate,0.35), 2),
      'bookings_30d', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled'),
      'bookings_prev', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status<>'cancelled'),
      'gmv_30d', coalesce(
        nullif((select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status='confirmed')
             + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-30), 0),
        (select (e.props->>'revenue_30d')::numeric from events e
          where e.tenant_id=t.id and e.name='tenant_rollup'
          order by e.at desc limit 1),
        0),
      'gmv_prev', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status='confirmed')
                + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-60 and p.on_date < current_date-30),
      'apps_30d', (select count(*) from applications a where a.tenant_id=t.id and a.created_at >= current_date-30),
      'events_30d', (select count(*) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'sessions_30d', (select count(distinct session_id) from events e where e.tenant_id=t.id and e.at >= current_date-30 and e.session_id is not null),
      'active_days_30d', (select count(distinct e.at::date) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'last_event_at', (select max(at) from events e where e.tenant_id=t.id),
      'errors_30d', (select count(*) from events e where e.tenant_id=t.id and e.name='client_error' and e.at >= current_date-30),
      'app_ver', (select props->>'ver' from events e where e.tenant_id=t.id and e.name='page_view' and e.props ? 'ver' order by e.at desc limit 1),
      'channel_mix', (select coalesce(jsonb_object_agg(src, cnt), '{}'::jsonb) from
        (select coalesce(source,'Website') src, count(*) cnt from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled' group by 1) m),
      'weekly_gmv', (select coalesce(jsonb_agg(wk order by wknum desc), '[]'::jsonb) from
        (select g.n as wknum,
          (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date >= current_date-(g.n*7+6) and b.date <= current_date-(g.n*7))
          + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-(g.n*7+6) and p.on_date <= current_date-(g.n*7)) as wk
         from generate_series(0,7) g(n)) w),
      'federated', exists (select 1 from events e where e.tenant_id=t.id and e.name='tenant_rollup'),
      'rollup_at', (select max(e.at) from events e where e.tenant_id=t.id and e.name='tenant_rollup'),
      'usage_daily', (select coalesce(jsonb_object_agg(d::text, cnt), '{}'::jsonb) from
        (select e.at::date d, count(*) cnt from events e where e.tenant_id=t.id and e.at >= current_date-13 group by 1) u)
    ) as obj
    from tenants t left join subscriptions s on s.tenant_id = t.id
    -- 0012: archived tenants stay in the database but leave the console
    where not coalesce((t.config ->> 'archived')::boolean, false)
  ) x;
  return result;
end $function$
;

-- ------------------------------------------------------------
-- GenAlpha is not paying for the platform — it predates it and runs on
-- its own project. Billing it 899 a month in a console that cannot see
-- it was the most misleading card on the page.
-- ------------------------------------------------------------
update subscriptions
   set plan = 'free', mrr = 0, status = 'active', tier = null
 where tenant_id = 'genalpha';

update tenants
   set config = coalesce(config, '{}'::jsonb)
              || jsonb_build_object('federated', true,
                                    'url', 'https://sujittarun.github.io/genAlpha-Manager-AndroidApp/')
 where id = 'genalpha';

do $$
declare v jsonb;
begin
  if (select mrr from subscriptions where tenant_id='genalpha') <> 0 then
    raise exception 'genalpha still billed';
  end if;
  if not coalesce((select (config->>'federated')::boolean from tenants where id='genalpha'), false) then
    raise exception 'genalpha not marked federated';
  end if;

  -- operator_portfolio is operator-only, so borrow the claim for the
  -- length of this check. `true` scopes it to the transaction.
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);

  -- prove the fallback works, then take it back out
  insert into events (tenant_id, name, page, props)
  values ('genalpha','tenant_rollup','probe',
          jsonb_build_object('players', 42, 'revenue_30d', 31500, 'ver','probe'));

  select value into v from jsonb_array_elements(operator_portfolio()) value
   where value->>'tenant_id' = 'genalpha';

  if (v->>'active_players')::int <> 42 then
    raise exception 'rollup fallback not used: active_players=%', v->>'active_players';
  end if;
  if (v->>'gmv_30d')::numeric <> 31500 then
    raise exception 'rollup fallback not used for gmv: %', v->>'gmv_30d';
  end if;

  delete from events where tenant_id='genalpha' and page='probe';
  raise notice 'federated fallback works: 42 players, 31500 revenue';
end $$;
