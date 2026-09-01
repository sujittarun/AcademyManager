-- ============================================================
-- 2026-08-31h · The GenAlpha coach is assigned to the academy
-- scope: shared
--
-- "coach entered the PIN, can see students, can't mark them present —
--  'You are not assigned to that centre.'"
--
-- Everything was in place except one row. The Android PIN is the password of
-- a real account (SupabaseRepository.signInCoach -> signIn(COACH_EMAIL, pin)),
-- coach@genalphaacademy.in exists with am_role = 'coach' and tenant_id =
-- 'genalpha', and genalpha.mark_player_attendance deliberately admits a coach:
--
--     if not (auth_role() = 'coach' or is_service()) then
--       perform assert_staff_or_service('genalpha');
--     end if;
--
-- But it then calls assert_attendance_access, which for a coach looks up the
-- batch's centre and checks it against my_centres() — and my_centres reads
-- staff_scopes, which had rows for raj and ska and NONE for genalpha. An empty
-- centre list means every batch is somebody else's, so every mark was refused
-- with that exact message.
--
-- Reading the students worked because that path does not go through the centre
-- check, which is why it looked like a half-working login rather than a
-- missing assignment.
--
-- GenAlpha is a single-centre academy: one centre (109) and five batches, all
-- on it, and every enrolment uses one of those five. So one scope row covers
-- the whole register. set_staff_scope is used rather than a raw insert because
-- it refuses a centre belonging to another academy.
-- ============================================================

do $$
declare v_centre bigint;
begin
  select id into v_centre from centres where tenant_id = 'genalpha';
  if v_centre is null then raise exception 'genalpha has no centre to assign'; end if;
  if (select count(*) from centres where tenant_id = 'genalpha') <> 1 then
    raise exception 'genalpha now has more than one centre; assign them explicitly';
  end if;

  perform set_staff_scope('genalpha', 'coach@genalphaacademy.in',
                          'GenAlpha Coach', ARRAY[v_centre], true);
end $$;

do $$
declare v_centres bigint[]; v_centre bigint; v_batches int;
begin
  select id into v_centre from centres where tenant_id = 'genalpha';

  select centre_ids into v_centres from staff_scopes
   where tenant_id = 'genalpha' and lower(email) = 'coach@genalphaacademy.in' and active;
  if v_centres is null or not (v_centre = any(v_centres)) then
    raise exception 'the coach is still not assigned to centre %', v_centre;
  end if;

  -- Every batch a coach could be asked to mark must be inside that centre,
  -- or the same error comes back for whichever one is not.
  select count(*) into v_batches from batches
   where tenant_id = 'genalpha' and centre_id is distinct from v_centre;
  if v_batches > 0 then
    raise exception '% GenAlpha batches sit outside the assigned centre', v_batches;
  end if;

  raise notice 'coach@genalphaacademy.in assigned to centre %, all batches covered', v_centre;
end $$;
