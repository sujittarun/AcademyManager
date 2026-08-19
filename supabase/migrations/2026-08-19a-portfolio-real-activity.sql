-- ============================================================
-- 2026-08-19a · The console ranked clients by instrumentation, not use
-- scope: shared
--
-- Every "usage" figure on the Academies tab is counted from the `events`
-- table:
--
--   usage_daily      count(*) from events, per day, 14 days
--   active_days_30d  count(distinct at::date) from events
--   sessions_30d     count(distinct session_id) from events
--   events_30d       count(*) from events
--
-- events is TELEMETRY. A tenant appears busy in proportion to how well
-- its app was instrumented, which has nothing to do with the academy.
-- The proof is on the platform right now:
--
--   genalpha  81 real families, live WhatsApp money, and until
--             2026-08-12 its web app emitted exactly three event kinds —
--             page_view, client_error, tenant_rollup. No actions at all.
--   mpp       0 members, 0 payments, 0 bookings, and 12 event kinds.
--   ska       294 events in its first two days, every one of them us
--             building it.
--
-- So the tab has been telling the operator that the empty tenant is
-- busier than the one taking money from 81 families, and that a tenant
-- under construction is the most active account on the platform.
--
-- WHAT REPLACES IT. Count rows, not events. A payment recorded, a member
-- added, a booking taken, a session held, an application received, an
-- expense logged — these are writes to shared tables, identical in
-- meaning for every tenant, and completely independent of whether
-- anybody remembered to call amReport(). A tenant cannot look busy by
-- being well-instrumented, and cannot look idle by being badly
-- instrumented.
--
--   actions_30d    business writes in the last 30 days
--   actions_prev   the 30 days before that, so the card can show a trend
--   last_write_at  the last real write, as distinct from last_event_at,
--                  which only says when the app last phoned home
--
-- The telemetry figures are NOT removed. They answer a real question —
-- "is the app running, and is it erroring" — and they stay in the
-- detail view where that question belongs. What changes is that they
-- stop being the headline number on a business dashboard.
--
-- attendance_records has tenant_id but no created_at, so sessions stands
-- in for attendance: a session created is the write a coach makes.
-- ============================================================

do $$
declare src text; fixed text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'operator_portfolio';
  if src is null then raise exception 'operator_portfolio is missing'; end if;

  fixed := replace(src,
    $old$    'usage_daily', ($old$,
    $new$    -- Counted from rows, not from events. See 2026-08-19a: the
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
    'usage_daily', ($new$);

  if fixed = src then
    raise exception 'could not find the usage_daily key to insert before';
  end if;
  execute fixed;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare j jsonb; n_ska int; n_ga int; n_mpp int; n_missing int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  perform set_config('role','authenticated', true);
  select operator_portfolio() into j;
  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- every tenant carries the three new keys
  select count(*) into n_missing
    from jsonb_array_elements(j) e
   where not (e ? 'actions_30d' and e ? 'actions_prev' and e ? 'last_write_at');
  if n_missing > 0 then
    raise exception '% tenant(s) came back without the new activity keys', n_missing;
  end if;

  select (e->>'actions_30d')::int into n_ga
    from jsonb_array_elements(j) e where e->>'tenant_id'='genalpha';
  select (e->>'actions_30d')::int into n_mpp
    from jsonb_array_elements(j) e where e->>'tenant_id'='mpp';
  select (e->>'actions_30d')::int into n_ska
    from jsonb_array_elements(j) e where e->>'tenant_id'='ska';

  -- The whole point: the tenant with 81 paying families must not rank
  -- below the empty one. If this ever flips, the metric has drifted back
  -- to counting telemetry.
  if n_ga <= n_mpp then
    raise exception 'genalpha (%) is not ahead of mpp (%) — the metric is still measuring instrumentation', n_ga, n_mpp;
  end if;

  raise notice 'business actions 30d: genalpha=%, mpp=%, ska=%', n_ga, n_mpp, n_ska;
end $$;
