-- ============================================================
-- 0012 · Remove the demo tenant; show Pride instead of MatchPoint
-- scope: shared
--
-- The console lists every row in `tenants`, so both of these are data
-- changes, not code changes.
--
-- 1. demo-courts was added for testing. Deleted outright, per request.
--    Its rows are backed up first to supabase/backups/ — one booking,
--    two integrations, one sync_log line, nothing else.
--
-- 2. MatchPoint is shelved; Pride is the client. Rather than delete
--    MatchPoint's ten members and its player-tracking history, it is
--    ARCHIVED — a config flag that operator_portfolio filters out. The
--    console stops showing it, the data stays, and it is one update to
--    put back. Its trial subscription moves to mpp, because that is the
--    conversation that is actually live.
--
-- Deliberately NOT touched: machaxi and genalpha. Not part of the ask.
-- ============================================================

-- ------------------------------------------------------------
-- 1 · demo-courts
-- ------------------------------------------------------------
delete from sync_log      where tenant_id = 'demo-courts';
delete from integrations  where tenant_id = 'demo-courts';
delete from bookings      where tenant_id = 'demo-courts';
delete from events        where tenant_id = 'demo-courts';
delete from tenants       where id        = 'demo-courts';

-- ------------------------------------------------------------
-- 2 · MatchPoint -> Match Point Pride
-- ------------------------------------------------------------
update tenants
   set config = coalesce(config, '{}'::jsonb) || jsonb_build_object('archived', true)
 where id = 'matchpoint';

-- Pride takes over the trial, and gains the link the console uses for
-- its "Open tenant console" button.
update subscriptions set tenant_id = 'mpp' where tenant_id = 'matchpoint';

update tenants
   set config = coalesce(config, '{}'::jsonb)
              || jsonb_build_object('url', 'https://sujittarun.github.io/MatchPointPride/')
 where id = 'mpp';

-- ------------------------------------------------------------
-- operator_portfolio(): hide archived tenants.
--
-- Written out in full rather than rewritten by string replacement at
-- run time. The clever version was two `replace()` calls against
-- pg_get_functiondef, which is unreviewable in a diff and fails
-- silently the day someone reformats the source. The body below is the
-- live definition verbatim; the only change is the `where`.
-- ------------------------------------------------------------
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
      'active_players', (select count(*) from members m where m.tenant_id=t.id and m.status in ('active','due')),
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
      'gmv_30d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status='confirmed')
               + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-30),
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
-- Assert the outcome rather than trusting it.
-- ------------------------------------------------------------
do $$
declare v_ids text;
begin
  if exists (select 1 from tenants where id = 'demo-courts') then
    raise exception 'demo-courts still present';
  end if;
  if exists (select 1 from bookings where tenant_id = 'demo-courts') then
    raise exception 'demo-courts bookings still present';
  end if;
  if not exists (select 1 from subscriptions where tenant_id = 'mpp') then
    raise exception 'the trial did not move to mpp';
  end if;
  if (select config ->> 'url' from tenants where id = 'mpp') is null then
    raise exception 'mpp has no console url';
  end if;
  if not coalesce((select (config->>'archived')::boolean from tenants where id='matchpoint'), false) then
    raise exception 'matchpoint not archived';
  end if;
  -- matchpoint's data must survive being archived
  if (select count(*) from members where tenant_id = 'matchpoint') = 0 then
    raise exception 'archiving matchpoint deleted its members';
  end if;

  select string_agg(id, ', ' order by id) into v_ids from tenants;
  raise notice 'tenants now: %', v_ids;
end $$;
