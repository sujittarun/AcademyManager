-- ============================================================
-- 2026-08-12f · A coach tier that is actually enforced
-- scope: shared
--
-- The Android app gates its roster behind a six-digit PIN compared in
-- Kotlin (AcademyApp.kt:238, MANAGER_VIEW_PIN = "290326"). That is a UI
-- gate, not access control — the constant is in the git repo and
-- extractable from any APK — and it fetches nothing, which is why the
-- roster stayed blank after entering it and only appeared once a staff
-- member signed in. The data was coming from the staff session.
--
-- PLATFORM.md already calls this out: "A PIN compared in JavaScript is
-- not access control. Where a tenant app uses one, it must sit on top of
-- a real Supabase session, not instead of one."
--
-- So the PIN becomes the password of a real coach account. The coach
-- still types six digits; the app signs in with a fixed address and that
-- PIN, and gets a genuine session with am_role='coach'. Rotating the PIN
-- is changing a password — no app release.
--
-- WHAT A COACH MAY SEE, decided with the owner: roster and attendance,
-- and NO PHONE NUMBERS. Not money, not addresses, not parent contacts.
-- A leaked PIN then costs a list of first names and who turned up, which
-- is a different order of problem from 81 families' contact details.
--
-- HOW IT IS ENFORCED. Not by the app choosing what to render — by the
-- database. genalpha.students stays staff-only and untouched. Coaches get
-- their own SECURITY DEFINER functions whose SELECT list simply has no
-- phone column, so there is nothing to leak even if the client asks. The
-- grant is the gate, which is the pattern this platform already uses for
-- whatsapp_credentials() and my_attendance_insights().
-- ============================================================

create or replace function genalpha.coach_roster()
returns table (
  id            uuid,
  name          text,
  age           integer,
  time_slot     text,
  discontinued  boolean,
  jersey_size   text,
  reg_no        bigint
)
language sql
stable
security definer
set search_path = genalpha, public
as $$
  select d.legacy_uuid, m.name,
         coalesce(d.age, extract(year from age(m.dob))::integer),
         d.time_slot,
         m.status = 'discontinued',
         d.jersey_size,
         m.reg_no
    from members m
    join genalpha.student_details d on d.member_id = m.id
   where m.tenant_id = 'genalpha'
     and (
       -- a coach, or genalpha's own staff, or the operator
       auth_role() = 'coach'
       or (auth_role() = 'staff' and auth_tenant() = 'genalpha')
       or auth_role() = 'operator'
       or is_service()
     )
   order by m.name;
$$;

comment on function genalpha.coach_roster() is
  'Roster for the coach tier: names, ages, slots, jersey sizes. No phone numbers, no addresses, no money — the columns are simply not in the SELECT, so a client cannot ask for them.';

create or replace function genalpha.coach_attendance(
  p_from date default (current_date - 30),
  p_to   date default current_date
)
returns table (
  student_id      uuid,
  attendance_date date,
  status          text,
  marked_at       timestamptz
)
language sql
stable
security definer
set search_path = genalpha, public
as $$
  select d.legacy_uuid, s.on_date, ar.status, ar.marked_at
    from attendance_records ar
    join sessions s on s.id = ar.session_id
    join enrollments e on e.id = ar.enrollment_id
    join genalpha.student_details d on d.member_id = e.member_id
   where ar.tenant_id = 'genalpha'
     and s.on_date between p_from and p_to
     and (
       auth_role() = 'coach'
       or (auth_role() = 'staff' and auth_tenant() = 'genalpha')
       or auth_role() = 'operator'
       or is_service()
     );
$$;

comment on function genalpha.coach_attendance(date, date) is
  'Attendance for the coach tier, by legacy student uuid so the app''s existing ids keep working.';

revoke execute on function genalpha.coach_roster() from public, anon;
revoke execute on function genalpha.coach_attendance(date, date) from public, anon;
grant  execute on function genalpha.coach_roster() to authenticated, service_role;
grant  execute on function genalpha.coach_attendance(date, date) to authenticated, service_role;

-- Marking attendance: the coach's one write. It already asserts
-- assert_staff_or_service, which a coach fails, so it is widened to the
-- narrower guard PLATFORM.md prescribes — never by loosening
-- assert_staff(), which guards record_fee_payment and every other
-- definer function.
do $$
declare src text; fixed text;
begin
  for src in
    select pg_get_functiondef(p.oid) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='genalpha'
      and p.proname in ('mark_player_attendance','unmark_player_attendance')
  loop
    fixed := replace(src,
      $old$  perform assert_staff_or_service('genalpha');$old$,
      $new$  -- A coach may mark a register and nothing else. Widened here
  -- rather than in assert_staff(), which also guards record_fee_payment,
  -- compute_payouts and reminder_queue.
  if not (auth_role() = 'coach' or is_service()) then
    perform assert_staff_or_service('genalpha');
  end if;$new$);
    if fixed = src then raise exception 'could not find the guard to widen'; end if;
    execute fixed;
  end loop;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; cols text;
begin
  -- The roster cannot return a phone number by construction: the columns
  -- are simply not in the function's output. Assert on the actual output
  -- names rather than trusting the SELECT list to stay as written.
  select string_agg(unnest, ',') into cols
    from unnest((select proargnames from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='genalpha' and p.proname='coach_roster'));
  if cols ~* 'phone|address|contact|amount|fee' then
    raise exception 'coach_roster exposes something it should not: %', cols;
  end if;
  raise notice 'coach_roster returns: %', cols;

  -- it answers for the operator/service caller running this migration
  select count(*) into n from genalpha.coach_roster();
  if n <> 81 then raise exception 'coach_roster returned % players, expected 81', n; end if;

  select count(*) into n from genalpha.coach_attendance(current_date - 60, current_date);
  raise notice 'coach_attendance returns % rows for the last 60 days', n;

  -- neither is reachable by anon
  if has_function_privilege('anon','genalpha.coach_roster()'::regprocedure,'execute') then
    raise exception 'coach_roster is anon-callable';
  end if;

  -- staff-only surfaces are unchanged: genalpha.students still has no
  -- coach path, so a coach cannot get phone numbers the long way round
  select count(*) into n from pg_policy p
    join pg_class c on c.oid=p.polrelid join pg_namespace ns on ns.oid=c.relnamespace
   where ns.nspname='public' and c.relname='members'
     and pg_get_expr(p.polqual, p.polrelid) like '%coach%';
  if n <> 0 then raise exception 'a policy on public.members now admits coach'; end if;

  raise notice 'coach tier: roster and attendance, no phones, enforced by the grant';
end $$;
