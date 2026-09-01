-- Can the GenAlpha coach actually mark a register?
--
-- Asked with a REAL coach JWT rather than by reading grants — the same
-- technique as 0039, and for the same reason: two platform outages were caused
-- by SQL that read correctly and behaved otherwise.

-- ------------------------------------------------------------
-- Owner's view: stash a real student and batch for the coach to use.
-- ------------------------------------------------------------
do $$
declare v_student uuid; v_batch bigint;
begin
  select d.legacy_uuid into v_student
    from genalpha.student_details d
    join members m on m.id = d.member_id
    join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.status = 'active' and e.batch_id is not null
   limit 1;
  if v_student is null then raise exception 'fixture: no active GenAlpha player with a batch'; end if;

  select e.batch_id into v_batch
    from genalpha.student_details d
    join enrollments e on e.member_id = d.member_id
   where d.legacy_uuid = v_student limit 1;

  perform set_config('t31h.student', v_student::text, true);
  perform set_config('t31h.batch', v_batch::text, true);
end $$;

-- ------------------------------------------------------------
-- Now BE the coach. This is the account the Android PIN signs in as.
-- ------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"afdc8460-c697-4fcb-95ff-121fe76e28ff","email":"coach@genalphaacademy.in","app_metadata":{"am_role":"coach","tenant_id":"genalpha"}}';

do $$
declare fails text[] := '{}'; ok boolean; v_student uuid; v_batch bigint; v_centres bigint[];
begin
  v_student := current_setting('t31h.student', true)::uuid;
  v_batch   := current_setting('t31h.batch', true)::bigint;

  -- 1. The coach is assigned somewhere at all.
  v_centres := my_centres('genalpha');
  if v_centres is null or array_length(v_centres, 1) is null then
    fails := fails || ARRAY['my_centres() is empty — the coach is assigned to no centre'];
  end if;

  -- 2. The centre check passes for a real batch. This is the exact call that
  --    raised "You are not assigned to that centre."
  ok := true;
  begin
    perform assert_attendance_access('genalpha', v_batch);
  exception when others then
    ok := false;
    fails := fails || ARRAY['assert_attendance_access refused batch ' || v_batch || ': ' || sqlerrm];
  end;

  -- 3. And the register can actually be marked, end to end.
  ok := true;
  begin
    perform genalpha.mark_player_attendance(v_student, current_date);
  exception when others then
    ok := false;
    fails := fails || ARRAY['mark_player_attendance failed: ' || sqlerrm];
  end;

  -- 4. Undo works too, or a mis-tap is permanent for the coach.
  if ok then
    begin
      perform genalpha.unmark_player_attendance(v_student, current_date);
    exception when others then
      fails := fails || ARRAY['unmark_player_attendance failed: ' || sqlerrm];
    end;
  end if;

  -- 5. The coach must still NOT be able to touch money. Widening attendance
  --    must not have widened anything else.
  ok := false;
  begin
    perform reminder_queue('genalpha');
  exception when others then ok := true; end;
  if not ok then
    fails := fails || ARRAY['a coach can read reminder_queue — attendance access leaked into money'];
  end if;

  if array_length(fails, 1) is not null then
    raise exception 'coach attendance: %', array_to_string(fails, ' | ');
  end if;
end $$;

reset role;
