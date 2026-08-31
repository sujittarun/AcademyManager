-- ============================================================
-- 2026-08-25a · Watch two academies, and hear about changes instead of asking
-- scope: shared
--
-- TWO THINGS, both about the console doing less.
--
-- 1. WHICH ACADEMIES ARE WORTH LOOKING AT.
--
-- Measured over the last 24 hours: genalpha 28 events, mezzo 19, mpp 1,
-- and nothing at all from leo, raj, demo or ska. Six academies on the
-- board, two in use. The rest are not noise to be deleted — they are
-- real tenants with real history — but they should not be the first
-- thing on screen every morning.
--
-- `config.watch = false` marks one. It is deliberately NOT `archived`:
--
--   archived  = retired from the business. matchpoint is this, and
--               operator_portfolio() drops it entirely.
--   watch:false = still a tenant, still billable, still readable —
--               just not something to check daily.
--
-- The distinction matters for two of them specifically. `demo` is the
-- sales demo and `0012` decided ON PURPOSE that it stays visible rather
-- than hidden, so archiving it would quietly reverse a recorded
-- decision. `ska` was due to go live on 1 Sep 2026 and has not been
-- retired by anyone. Both are unwatched here, neither is archived, and
-- one flag brings either back.
--
-- The portfolio still returns them. Totals stay honest and nothing is
-- hidden from the database; the console simply folds them away behind a
-- count, and does not poll or subscribe to them.
--
-- 2. STOP ASKING EVERY FIFTEEN SECONDS.
--
-- The console polls because it had nothing better. Realtime is already
-- on for the tables that matter — payments, members, attendance_records,
-- enrollments, expenses, reminder_events — but NOT for `events`, which
-- is what the activity feed reads. So a fee could arrive live while the
-- activity list waited for the next poll.
--
-- Adding it means the console can subscribe and refresh only when a row
-- actually lands. Volume is trivial (28 events across the whole platform
-- yesterday), RLS still applies — `events_op_r` restricts SELECT to
-- operators, and Realtime enforces the same policy per subscriber — so
-- no tenant gains sight of another's telemetry.
--
-- Replica identity stays DEFAULT. That is enough for INSERT, which is
-- the only thing anyone subscribes to here; FULL would only matter for
-- RLS-filtered DELETEs, and nothing deletes telemetry.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Two academies are watched. The others are not.
-- ------------------------------------------------------------
update tenants
   set config = coalesce(config, '{}'::jsonb) || jsonb_build_object('watch', true)
 where id in ('mezzo', 'genalpha');

update tenants
   set config = coalesce(config, '{}'::jsonb) || jsonb_build_object('watch', false)
 where id not in ('mezzo', 'genalpha')
   and not coalesce((config ->> 'archived')::boolean, false);

-- ------------------------------------------------------------
-- 2. Telemetry joins the realtime publication
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public' and tablename = 'events'
  ) then
    alter publication supabase_realtime add table public.events;
    raise notice 'public.events added to supabase_realtime';
  else
    raise notice 'public.events was already published';
  end if;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $chk$
declare n int; r record;
begin
  -- a) exactly the two academies asked for are watched.
  --    An ARCHIVED tenant carries no watch flag and needs none — it is
  --    already absent from the console, so defaulting its missing key to
  --    "watched" and then complaining about it is the check being wrong,
  --    not the data. (matchpoint tripped exactly this on the first run.)
  select count(*) into n from tenants
   where coalesce((config->>'watch')::boolean, true)
     and not coalesce((config->>'archived')::boolean, false)
     and id not in ('mezzo','genalpha');
  if n > 0 then
    for r in select id from tenants
              where coalesce((config->>'watch')::boolean, true)
                and not coalesce((config->>'archived')::boolean, false)
                and id not in ('mezzo','genalpha') loop
      raise notice 'still watched but should not be: %', r.id;
    end loop;
    raise exception '% tenant(s) are still watched', n;
  end if;
  if (select count(*) from tenants where (config->>'watch')::boolean) <> 2 then
    raise exception 'expected exactly 2 watched academies';
  end if;

  -- b) NOTHING was archived by this file. Unwatching is not retiring,
  --    and demo staying visible is a decision 0012 made on purpose.
  select count(*) into n from tenants
   where coalesce((config->>'archived')::boolean,false) and id <> 'matchpoint';
  if n > 0 then raise exception 'this file archived % tenant(s); it must not', n; end if;

  -- c) every tenant still has its config intact
  if (select config->>'brand' from tenants where id='mezzo') is null
     or (select config->'reminders'->>'mode' from tenants where id='mezzo') <> 'simple' then
    raise exception 'mezzo config was damaged';
  end if;
  if (select config->>'url' from tenants where id='ska') is null then
    raise exception 'ska lost its app url';
  end if;

  -- d) the portfolio still returns everyone, so totals stay honest
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  select count(*) into n from jsonb_array_elements(operator_portfolio());
  if n < 6 then
    raise exception 'the portfolio dropped to % rows; unwatching must not hide anyone from it', n;
  end if;
  perform set_config('request.jwt.claims', null, true);

  -- e) events is published, and the tables that were already published
  --    still are
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='events') then
    raise exception 'events is not published, so the activity feed cannot go live';
  end if;
  select count(*) into n from pg_publication_tables
   where pubname='supabase_realtime' and schemaname='public'
     and tablename in ('payments','members','attendance_records','enrollments','expenses','reminder_events');
  if n <> 6 then
    raise exception 'only % of the 6 business tables are still published', n;
  end if;

  -- f) anon still cannot read telemetry. Publishing a table to realtime
  --    does not change RLS, but this is the check worth having anyway.
  if has_table_privilege('anon', 'public.events', 'select') then
    raise exception 'anon can select from events';
  end if;

  raise notice 'watching mezzo + genalpha; events now published; portfolio still returns everyone';
end $chk$;
