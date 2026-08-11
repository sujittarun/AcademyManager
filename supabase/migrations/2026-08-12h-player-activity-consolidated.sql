-- ============================================================
-- 2026-08-12h · Port player_activity_consolidated off the legacy project
-- scope: shared
--
-- The last object GenAlpha's own project has that this one does not. It
-- is a read-only reporting view — one row per thing that happened to a
-- player, timeline entries and WhatsApp reminders unioned into a single
-- feed with the player's name attached — and the owner uses it directly
-- in the SQL editor.
--
-- Porting it is a precondition for deleting hwxhigwaklzedxufwedv, not a
-- feature request: everything else was verified identical today (81
-- students, 1,477 attendance, 102 admissions, 75 storage objects, and
-- every table at or above its legacy count), and this view was the one
-- remaining difference.
--
-- FAITHFUL, WITH ONE ADDITION. The column list and order are the legacy
-- definition unchanged, so existing queries keep working. `student_id`
-- is appended at the END — the legacy view identified a player only by
-- name, which is ambiguous the moment two families share a surname, and
-- this database has two Ayaans already. Appending rather than inserting
-- keeps `select *` consumers positionally intact.
--
-- SECURITY: security_invoker = true, deliberately.
--
-- The three sources disagree about whose rights apply:
--   genalpha.students          security_invoker = false (owner rights,
--                              with its own role guard from 2026-08-12g)
--   genalpha.student_timeline  security_invoker = true
--   genalpha.reminder_events   security_invoker = true
--
-- Running this view as its owner would bypass RLS on member_timeline and
-- the reminder tables underneath. It must not: reminder_events carries
-- `amount`, `parent_phone` and `manager_phone`, so an owner-rights view
-- would hand a coach every family's phone number and every amount owed —
-- exactly what 2026-08-12g nulled out of the roster.
--
-- With invoker rights the two halves are governed by the policies that
-- already exist: staff read the whole feed, and a coach reads nothing
-- from it, because every policy on those tables tests auth_role() =
-- 'staff'. A coach losing the activity feed is the correct outcome, not
-- a gap to widen later.
-- ============================================================

create or replace view genalpha.player_activity_consolidated
with (security_invoker = true) as
  select s.name           as student_name,
         st.created_at    as event_time,
         st.event_type    as activity_type,
         st.title         as activity_title,
         st.details       as activity_details,
         st.changed_by    as performed_by,
         null::text       as status_info,
         s.id             as student_id
    from genalpha.students s
    join genalpha.student_timeline st on st.student_id = s.id
  union all
  select s.name              as student_name,
         re.created_at       as event_time,
         re.reminder_type    as activity_type,
         'WhatsApp Reminder' as activity_title,
         re.message_preview  as activity_details,
         re.created_by       as performed_by,
         re.status           as status_info,
         s.id                as student_id
    from genalpha.students s
    join genalpha.reminder_events re on re.student_id = s.id;

comment on view genalpha.player_activity_consolidated is
  'One feed of everything that happened to a GenAlpha player: student_timeline plus reminder_events, with the player name. Ported from the legacy project 2026-08-12h. security_invoker so a coach cannot read the amounts and phone numbers in reminder_events.';

revoke all on genalpha.player_activity_consolidated from public, anon;
grant select on genalpha.player_activity_consolidated to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n_total int; n_tl int; n_re int; n_named int; n_coach int; n_anon int;
begin
  select count(*) into n_tl from genalpha.student_timeline st
    join genalpha.students s on s.id = st.student_id;
  select count(*) into n_re from genalpha.reminder_events re
    join genalpha.students s on s.id = re.student_id;
  select count(*) into n_total from genalpha.player_activity_consolidated;

  if n_total <> n_tl + n_re then
    raise exception 'the union returned % rows, but its two halves hold % + %',
      n_total, n_tl, n_re;
  end if;
  if n_total = 0 then
    raise exception 'the view is empty; the legacy one held ~3,625 rows';
  end if;

  -- The whole point of the view is the name. If the join is wrong this
  -- still returns rows, just anonymous ones — so assert on content.
  select count(*) into n_named from genalpha.player_activity_consolidated
   where student_name is not null and student_name <> '';
  if n_named <> n_total then
    raise exception '% of % rows came back with no player name', n_total - n_named, n_total;
  end if;

  -- and both halves are actually present
  if not exists (select 1 from genalpha.player_activity_consolidated
                  where activity_title = 'WhatsApp Reminder') then
    raise exception 'no reminder rows in the feed';
  end if;
  if not exists (select 1 from genalpha.player_activity_consolidated
                  where activity_title <> 'WhatsApp Reminder') then
    raise exception 'no timeline rows in the feed';
  end if;

  raise notice 'player_activity_consolidated: % rows (% timeline + % reminders)',
    n_total, n_tl, n_re;
end $$;

-- A coach must not reach it, because reminder_events carries amounts and
-- phone numbers. Asserted by signing in as one rather than by reading
-- the grants — the 0039 lesson.
do $$
declare n_coach int;
begin
  perform set_config('request.jwt.claims', json_build_object(
    'role','authenticated',
    'sub', coalesce((select id from auth.users where email='coach@genalphaacademy.in')::text,
                    gen_random_uuid()::text),
    'app_metadata', json_build_object('am_role','coach','tenant_id','genalpha'))::text, true);
  perform set_config('role','authenticated', true);

  select count(*) into n_coach from genalpha.player_activity_consolidated;

  reset role;
  perform set_config('request.jwt.claims', null, true);

  if n_coach <> 0 then
    raise exception 'a coach can read % rows of the activity feed, including amounts and phone numbers', n_coach;
  end if;
  raise notice 'a coach reads 0 rows of the activity feed, as intended';
end $$;

-- anon must have no grant at all
do $$
begin
  if has_table_privilege('anon', 'genalpha.player_activity_consolidated', 'select') then
    raise exception 'anon can select the activity feed';
  end if;
  raise notice 'anon has no grant on the activity feed';
end $$;
