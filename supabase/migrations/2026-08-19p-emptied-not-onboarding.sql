-- ============================================================
-- 2026-08-19p · MPP read "Onboarding" three weeks after it was handed over
-- scope: shared
--
-- The console's health rule is `last_write_at is null -> Onboarding`, and
-- last_write_at is the newest created_at across payments, members,
-- bookings, sessions, applications and expenses. MPP has none of those
-- rows, so it fell through to Onboarding.
--
-- It is not onboarding. It was provisioned, used properly for a week —
-- 123 action events between 29 Jul and 4 Aug: attendance_marked,
-- student_added, payment_recorded — and then deliberately emptied for
-- handover on 2026-08-04 (commit 0588583, with the backup asserted in the
-- same transaction). The rows are gone on purpose. "Onboarding" says we
-- are midway through setting them up, which is the opposite of what
-- happened and the sort of thing acted on wrongly.
--
-- Row counts cannot separate the two cases, because both are zero. The
-- events table can: it is append-only and was not part of the wipe, so
-- the work is still on record even though its output is not.
--
-- Two keys added, so the console can tell:
--
--     action_events_ever   somebody DID something, ever
--     last_action_at       when they last did
--
--     no rows, no actions ever    -> Onboarding  (genuinely new)
--     no rows, actions in history -> Emptied     (worked, then cleared)
--
-- ADDITIVE ONLY. This file is the live definition of operator_portfolio()
-- with those two keys inserted and nothing else touched — generated from
-- pg_get_functiondef rather than retyped, so the other ~40 keys cannot
-- drift by transcription.
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

      /* 2026-08-19p — row counts cannot tell "never started" from
         "started, then cleared": both are zero. events is append-only
         and survived MPP's handover wipe, so it still records that 123
         real actions happened there between 29 Jul and 4 Aug. */
      'action_events_ever', (select count(*) from events e where e.tenant_id=t.id
                               and e.name not in ('page_view','client_error','tenant_rollup')),
      'last_action_at',     (select max(e.at) from events e where e.tenant_id=t.id
                               and e.name not in ('page_view','client_error','tenant_rollup')),
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
      -- Counted from rows, not from events. See 2026-08-19a: the
    -- telemetry figures below measure how well a tenant's app was
    -- instrumented, which is not the same question as whether the
    -- academy is being used.
    'actions_30d', (
       select coalesce(sum(c),0) from (
         select count(*) c from payments     where tenant_id=t.id and created_at >= now()-interval '30 days'
         union all select count(*) from members  where tenant_id=t.id and created_at >= now()-interval '30 days'
         union all select count(*) from bookings where tenant_id=t.id and created_at >= now()-interval '30 days'
         union all select count(*) from sessions where tenant_id=t.id and created_at >= now()-interval '30 days'
         union all select count(*) from applications where tenant_id=t.id and created_at >= now()-interval '30 days'
         union all select count(*) from expenses where tenant_id=t.id and created_at >= now()-interval '30 days'
       ) x),
    'actions_prev', (
       select coalesce(sum(c),0) from (
         select count(*) c from payments     where tenant_id=t.id and created_at >= now()-interval '60 days' and created_at < now()-interval '30 days'
         union all select count(*) from members  where tenant_id=t.id and created_at >= now()-interval '60 days' and created_at < now()-interval '30 days'
         union all select count(*) from bookings where tenant_id=t.id and created_at >= now()-interval '60 days' and created_at < now()-interval '30 days'
         union all select count(*) from sessions where tenant_id=t.id and created_at >= now()-interval '60 days' and created_at < now()-interval '30 days'
         union all select count(*) from applications where tenant_id=t.id and created_at >= now()-interval '60 days' and created_at < now()-interval '30 days'
         union all select count(*) from expenses where tenant_id=t.id and created_at >= now()-interval '60 days' and created_at < now()-interval '30 days'
       ) x),
    'last_write_at', (
       select max(w) from (
         select max(created_at) w from payments  where tenant_id=t.id
         union all select max(created_at) from members  where tenant_id=t.id
         union all select max(created_at) from bookings where tenant_id=t.id
         union all select max(created_at) from sessions where tenant_id=t.id
         union all select max(created_at) from applications where tenant_id=t.id
         union all select max(created_at) from expenses where tenant_id=t.id
       ) x),
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


revoke execute on function public.operator_portfolio() from public, anon;
grant  execute on function public.operator_portfolio() to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks — reads only
-- ------------------------------------------------------------
do $chk$
declare v jsonb; r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  v := operator_portfolio();

  -- a) every tenant carries both new keys
  select count(*) into n from jsonb_array_elements(v) e
   where not (e ? 'action_events_ever') or not (e ? 'last_action_at');
  if n > 0 then raise exception '% row(s) missing the new keys', n; end if;

  -- b) the row this file exists for: no writes, but real work on record
  select e into r from jsonb_array_elements(v) e where e->>'tenant_id' = 'mpp';
  if r is null then raise exception 'mpp is not in the portfolio at all'; end if;
  if r->>'last_write_at' is not null then
    raise exception 'mpp has rows again (%); re-read this file before trusting it', r->>'last_write_at';
  end if;
  if (r->>'action_events_ever')::int < 100 then
    raise exception 'mpp shows only % action events; expected its 123', r->>'action_events_ever';
  end if;

  -- c) and the keys that were already there still are
  if (r->>'events_30d') is null or (r->>'mrr') is null or (r->>'name') is null then
    raise exception 'the replace dropped existing keys';
  end if;

  -- d) still operator-only
  if has_function_privilege('anon', 'public.operator_portfolio()', 'execute') then
    raise exception 'anon can read the portfolio';
  end if;

  perform set_config('request.jwt.claims', null, true);
  raise notice 'mpp: 0 rows, % action events on record, last %',
    r->>'action_events_ever', r->>'last_action_at';
end $chk$;
