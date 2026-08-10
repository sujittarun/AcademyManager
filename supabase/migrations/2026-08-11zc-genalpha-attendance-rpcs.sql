-- ============================================================
-- 2026-08-11zc · Attendance cannot be marked at all
-- scope: shared
--
-- script.js:7378 picks 'mark_player_attendance' or
-- 'unmark_player_attendance' and calls it with {p_student_id,
-- p_attendance_date}. Neither exists anywhere on this platform. They were
-- public.* functions on GenAlpha's own project, and 2026-08-10p ported
-- three admission RPCs, not these.
--
-- Every tick returns PGRST202. The checkbox flips optimistically and
-- reverts a moment later with a toast. Reads are unaffected, so the
-- register renders fully populated and looks healthy — which is why this
-- survived the cutover unnoticed.
--
-- Argument names are load-bearing: PostgREST matches RPC arguments by
-- NAME, so these must be exactly p_student_id and p_attendance_date or
-- the call 404s just as it does now.
--
-- Both delegate to the platform's mark_attendance(). GenAlpha's 1,477
-- flat rows were migrated into the batch/session model by 2026-08-11g,
-- which deleted the flat rows deliberately, so writing public.attendance
-- directly would create a second attendance store the shared functions
-- cannot see — precisely the split PLATFORM.md documents under "what
-- case 4 actually cost".
-- ============================================================

create or replace function genalpha.mark_player_attendance(
  p_student_id     uuid,
  p_attendance_date date
)
returns jsonb
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare
  v_member     bigint;
  v_enrollment bigint;
  v_batch      bigint;
begin
  perform assert_staff_or_service('genalpha');

  select d.member_id into v_member
    from genalpha.student_details d where d.legacy_uuid = p_student_id;
  if v_member is null then
    raise exception 'No GenAlpha player with id %', p_student_id;
  end if;

  select e.id, e.batch_id into v_enrollment, v_batch
    from enrollments e
   where e.tenant_id = 'genalpha' and e.member_id = v_member
   order by e.id limit 1;
  if v_enrollment is null then
    raise exception 'That player has no enrollment to mark attendance against.';
  end if;
  if v_batch is null then
    raise exception 'That player''s enrollment has no batch, so there is no register to mark.';
  end if;

  return mark_attendance('genalpha', v_batch, p_attendance_date, v_enrollment, 'present', null);
end $$;

create or replace function genalpha.unmark_player_attendance(
  p_student_id     uuid,
  p_attendance_date date
)
returns jsonb
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare
  v_member     bigint;
  v_enrollment bigint;
  v_batch      bigint;
begin
  perform assert_staff_or_service('genalpha');

  select d.member_id into v_member
    from genalpha.student_details d where d.legacy_uuid = p_student_id;
  if v_member is null then
    raise exception 'No GenAlpha player with id %', p_student_id;
  end if;

  select e.id, e.batch_id into v_enrollment, v_batch
    from enrollments e
   where e.tenant_id = 'genalpha' and e.member_id = v_member
   order by e.id limit 1;
  if v_enrollment is null then
    raise exception 'That player has no enrollment to mark attendance against.';
  end if;

  -- GenAlpha's model has no 'absent': a player is on the register or not.
  -- mark_attendance owns the write either way, so unmarking sets the
  -- status rather than deleting the row — the register keeps the fact
  -- that someone looked, which is what an audit of a child's attendance
  -- actually needs.
  return mark_attendance('genalpha', v_batch, p_attendance_date, v_enrollment, 'absent', null);
end $$;

comment on function genalpha.mark_player_attendance(uuid, date) is
  'Marks a GenAlpha player present. Argument names are what the app sends; PostgREST matches RPCs by argument name.';
comment on function genalpha.unmark_player_attendance(uuid, date) is
  'Marks a GenAlpha player absent. GenAlpha''s UI models this as un-ticking; the platform records it as a status.';

revoke execute on function genalpha.mark_player_attendance(uuid, date)   from public, anon;
revoke execute on function genalpha.unmark_player_attendance(uuid, date) from public, anon;
grant  execute on function genalpha.mark_player_attendance(uuid, date)   to authenticated, service_role;
grant  execute on function genalpha.unmark_player_attendance(uuid, date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v_student uuid; v_before int; v_after int; r jsonb; v_date date := current_date;
begin
  -- Reachable by the browser role, closed to anon.
  if not has_function_privilege('authenticated',
       'genalpha.mark_player_attendance(uuid,date)'::regprocedure, 'execute') then
    raise exception 'the app still cannot call mark_player_attendance';
  end if;
  if has_function_privilege('anon',
       'genalpha.unmark_player_attendance(uuid,date)'::regprocedure, 'execute') then
    raise exception 'anon can mark attendance';
  end if;

  -- Argument NAMES, not just arity. A rename here is a silent 404 in the
  -- browser and looks identical to the bug being fixed.
  if pg_get_function_identity_arguments(
       'genalpha.mark_player_attendance(uuid,date)'::regprocedure)
     <> 'p_student_id uuid, p_attendance_date date' then
    raise exception 'the argument names do not match what the app sends';
  end if;

  -- Exercise it against a real player with a real batch, then undo.
  select d.legacy_uuid into v_student
    from genalpha.student_details d
    join enrollments e on e.member_id = d.member_id and e.tenant_id='genalpha'
   where e.batch_id is not null
   limit 1;
  if v_student is null then
    raise exception 'no GenAlpha player has a batch — attendance cannot work for anyone';
  end if;

  select count(*) into v_before from genalpha.attendance
   where student_id = v_student and attendance_date = v_date and status = 'present';

  r := genalpha.mark_player_attendance(v_student, v_date);

  select count(*) into v_after from genalpha.attendance
   where student_id = v_student and attendance_date = v_date and status = 'present';
  if v_after <> 1 then
    raise exception 'marking present produced % present rows, expected 1', v_after;
  end if;

  r := genalpha.unmark_player_attendance(v_student, v_date);
  select count(*) into v_after from genalpha.attendance
   where student_id = v_student and attendance_date = v_date and status = 'present';
  if v_after <> 0 then
    raise exception 'unmarking left % present rows', v_after;
  end if;

  -- and it must be visible to the shared function too, not just the view
  if not exists (
    select 1 from shared_fn_coverage() where tenant_id = 'genalpha'
  ) then
    raise notice 'shared_fn_coverage has no genalpha row to check';
  end if;

  raise notice 'attendance can be marked and unmarked again for GenAlpha';
end $$;
