-- The rejoin flow, exercised through the view the apps actually write to.
--
-- Every case drives genalpha.students (the view) and then asserts on
-- public.enrollments, because that is the table reminder_queue() reads and the
-- one the trigger used to leave behind. run-test.sh rolls the whole thing back.

do $$
declare
  v_id      uuid;
  v_member  bigint;
  v_status  text;
  v_disc    date;
  v_renew   date;
  v_queued  boolean;

  procedure_note text;
begin
  -- A player to experiment on: real shape, created here, rolled back after.
  insert into genalpha.students (name, age, time_slot, join_date, fees_paid, amount_paid,
                                 fee_plan, father_guardian_name, parent_contact_no, added_by)
  values ('ZZ Rejoin Probe', 10, '6AM', '2026-01-10', true, 3500,
          'monthly', 'Probe Parent', '9000000911', 'test harness')
  returning id into v_id;

  select member_id into v_member from genalpha.student_details where legacy_uuid = v_id;
  if v_member is null then raise exception 'fixture did not create a member'; end if;

  -- Writing to genalpha.students does NOT create an enrolment — only
  -- approve_admission does — so the probe needs one explicitly. An earlier
  -- version of this test skipped this, every UPDATE matched zero rows, and
  -- `if v_status <> 'active'` compared NULL and quietly did not fire. Five
  -- cases were passing on nothing at all. Hence the null guards below.
  --
  -- reminder_queue also inner-joins centres, so an enrolment without one is
  -- invisible to it whatever its status.
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                           joined_on, renewal_on, status)
  values ('genalpha', v_member,
          (select id from centres where tenant_id = 'genalpha' order by id limit 1),
          'cricket', 1, '2026-01-10', '2026-02-10', 'active');

  -- ---------- 1. A fresh player's enrolment is active ----------
  select status into v_status from enrollments where member_id = v_member;
  if v_status is null then raise exception '1. no enrolment row at all'; end if;
  if v_status <> 'active' then
    raise exception '1. new player enrolment is %, expected active', v_status;
  end if;

  -- ---------- 2. Discontinuing reaches the enrolment ----------
  update genalpha.students
     set discontinued = true, discontinued_at = '2026-03-01'
   where id = v_id;
  select status, discontinued_on into v_status, v_disc from enrollments where member_id = v_member;
  if v_status is null then raise exception '2. enrolment vanished'; end if;
  if v_status <> 'discontinued' then
    raise exception '2. enrolment is % after discontinue, expected discontinued', v_status;
  end if;
  if v_disc <> date '2026-03-01' then
    raise exception '2. enrolment discontinued_on is %, expected 2026-03-01', v_disc;
  end if;

  -- ---------- 3. A discontinued player is not chased ----------
  select exists (select 1 from reminder_queue('genalpha') q
                  where q.member_name = 'ZZ Rejoin Probe') into v_queued;
  if v_queued then raise exception '3. a discontinued player is in the reminder queue'; end if;

  -- ---------- 4. Rejoining puts the enrolment back ----------
  -- This is the case that was broken: the member went active and the
  -- enrolment stayed discontinued, so reminder_queue never saw them again.
  -- The rejoin date is today's IST date so case 6 can check the queue on a
  -- real rung of the ladder. It fires at -2, 0, +3, +5 and then daily to +14,
  -- so a player four days overdue is legitimately silent — an earlier version
  -- of this test asserted otherwise and failed, correctly.
  update genalpha.students
     set discontinued = false, discontinued_at = null, rejoined_at = ist_today()
   where id = v_id;
  select status, discontinued_on, renewal_on
    into v_status, v_disc, v_renew from enrollments where member_id = v_member;
  if v_status is null or v_renew is null then raise exception '4. enrolment vanished'; end if;
  if v_status <> 'active' then
    raise exception '4. enrolment is % after rejoin, expected active', v_status;
  end if;
  if v_disc is not null then
    raise exception '4. enrolment still carries discontinued_on %', v_disc;
  end if;

  -- ---------- 5. The break is not chargeable ----------
  -- renewal_on was 2026-02-10, six months before the return. The player owes
  -- from the day they came back, not for the months they were away.
  if v_renew <> ist_today() then
    raise exception '5. next fee due is %, expected the rejoin date %', v_renew, ist_today();
  end if;

  -- ---------- 6. A rejoined player is chased again ----------
  select exists (select 1 from reminder_queue('genalpha') q
                  where q.member_name = 'ZZ Rejoin Probe') into v_queued;
  if not v_queued then
    raise exception '6. a rejoined player who owes a fee is still not in the reminder queue';
  end if;

  -- ---------- 7. Paid beyond the rejoin date keeps the later date ----------
  -- A player who paid ahead, then took a break, must not have coverage taken
  -- away by returning.
  update enrollments set renewal_on = '2026-12-01' where member_id = v_member;
  update genalpha.students set discontinued = true, discontinued_at = '2026-09-01' where id = v_id;
  update genalpha.students
     set discontinued = false, discontinued_at = null, rejoined_at = '2026-10-05'
   where id = v_id;
  select renewal_on into v_renew from enrollments where member_id = v_member;
  if v_renew is null then raise exception '7. enrolment vanished'; end if;
  if v_renew <> date '2026-12-01' then
    raise exception '7. next fee due moved to % — paid-ahead coverage was taken away', v_renew;
  end if;

  -- ---------- 8. An unrelated edit leaves the status alone ----------
  update genalpha.students set time_slot = '5:30PM' where id = v_id;
  select status, renewal_on into v_status, v_renew from enrollments where member_id = v_member;
  if v_status is null or v_renew is null then raise exception '8. enrolment vanished'; end if;
  if v_status <> 'active' or v_renew <> date '2026-12-01' then
    raise exception '8. an unrelated edit changed status=% renewal_on=%', v_status, v_renew;
  end if;

  -- ---------- 9. Re-discontinuing after a rejoin still works ----------
  update genalpha.students set discontinued = true, discontinued_at = '2026-11-02' where id = v_id;
  select status, discontinued_on into v_status, v_disc from enrollments where member_id = v_member;
  if v_status is null then raise exception '9. enrolment vanished'; end if;
  if v_status <> 'discontinued' or v_disc <> date '2026-11-02' then
    raise exception '9. second discontinue left status=% on=%', v_status, v_disc;
  end if;

  raise notice 'OK: all nine rejoin scenarios hold';
end $$;
