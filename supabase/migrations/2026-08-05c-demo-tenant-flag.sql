-- ============================================================
-- 2026-08-05c · Mark a tenant as a sales demo
-- scope: shared
--
-- The Machaxi tenant is being retired and its app reused as a permanent
-- Academy Manager demo. A demo tenant is a real tenant — real rows, real
-- RLS, real SQL money functions — which is the whole point: a demo that
-- fakes its numbers demonstrates a product we do not sell.
--
-- But it must not be counted as a customer. Its bookings are invented, so
-- its GMV is invented, and left alone it would inflate MRR, GMV, adoption
-- and growth on the operator console.
--
-- The mechanism follows the existing 'federated' precedent exactly: one
-- boolean surfaced by operator_portfolio(), with the console deciding what
-- to do with it. Per-tenant behaviour goes in tenants.config jsonb, never
-- a new column on a shared table.
--
-- WHY NOT JUST HIDE IT (config.archived = true)?
-- Because operator_portfolio() filters archived tenants and platform_errors()
-- does not. An archived-but-live tenant's client errors would keep arriving
-- in the console's attention strip with no card to resolve them on — a
-- permanent unactionable alert. So the demo stays visible and labelled, and
-- the console excludes it from TOTALS only.
-- ============================================================

CREATE OR REPLACE FUNCTION public.operator_portfolio()
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
      -- 2026-08-05c: a sales demo is a real tenant on real SQL, so it stays
      -- VISIBLE and labelled rather than hidden. Hiding it would be worse:
      -- platform_errors() has no archived filter, so a hidden tenant's crashes
      -- reach the console's attention strip with no card to resolve them on.
      -- The console excludes demo rows from portfolio TOTALS, not from the table.
      'demo', coalesce((t.config ->> 'demo')::boolean, false),
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

comment on function public.operator_portfolio() is
  'Account-level portfolio for the operator console. Each tenant carries federated and demo flags; demo tenants are excluded from portfolio totals by the console, not hidden.';

-- ------------------------------------------------------------
-- The events canary must not be fooled by the demo.
--
-- events_flowing() is false when the sink has gone quiet despite recent
-- traffic. It exists because of the 3-hour outage in 0007, where anon
-- writes to events failed for EVERY tenant. A demo that is opened daily
-- would keep the canary green while every real tenant's telemetry was
-- dead — the canary would report health precisely when it mattered least.
-- ------------------------------------------------------------
create or replace function public.events_flowing()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from events e
     join tenants t on t.id = e.tenant_id
    where e.at >= now() - interval '24 hours'
      and not coalesce((t.config ->> 'demo')::boolean, false)
  )
$$;
comment on function public.events_flowing() is
  'Canary: false when the events sink has gone quiet in 24h. Demo tenants are excluded so a daily-opened demo cannot mask a platform-wide telemetry outage.';
revoke execute on function public.events_flowing() from public, anon;
grant execute on function public.events_flowing() to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v jsonb; n int;
begin
  -- operator_portfolio() is operator-only by design and has no service
  -- bypass, so the check has to present an operator claim. Deliberately
  -- NOT widening the guard: the console's own reach is the thing it
  -- protects, and a migration is not a reason to loosen it.
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);

  v := operator_portfolio();
  select count(*) into n from jsonb_array_elements(v) a where a ? 'demo';
  if n = 0 then raise exception 'operator_portfolio() exposes no demo key'; end if;
  if exists (select 1 from jsonb_array_elements(v) a where (a->>'demo')::boolean) then
    raise exception 'a tenant is already flagged demo before the demo exists';
  end if;

  -- the canary still sees real traffic
  if not events_flowing() then
    raise exception 'events_flowing() went false — real telemetry is not reaching the sink';
  end if;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'demo flag live; % tenants carry it, none set', n;
end $$;
