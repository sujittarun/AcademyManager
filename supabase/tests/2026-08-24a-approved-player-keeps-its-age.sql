-- Approving an admission that gives an AGE but no DATE OF BIRTH must leave a
-- player with an age on the roster. That combination became possible on
-- 2026-08-19g, and it is what put a null on KARTHIK - WUYYURU and stopped the
-- mobile roster loading for every player.
--
-- Driven through the real approve_admission, not by asserting on the
-- function body. Rolled back by run-test.sh.

do $$
declare
  v_admission uuid;
  v_member    bigint;
  v_age       integer;
  v_roster    integer;
begin
  -- ---------- an admission with an age and NO date of birth ----------
  insert into genalpha.admissions (
    applicant_name, nationality, date_of_birth, age, gender,
    father_guardian_name, parent_contact_no, emergency_contact_no,
    school_college, address, time_slot, join_date, fees_paid, amount_paid,
    fee_plan, consent_accepted, terms_accepted)
  values ('ZZ Age Only Probe', 'INDIAN', null, 11, 'M',
          'Probe Parent', '9000000921', '9000000922',
          'Probe School', 'Probe Address', '6AM', current_date, false, 0,
          'monthly', true, true)
  returning id into v_admission;

  perform genalpha.approve_admission(v_admission, 'test harness', '');

  select approved_member_id into v_member
    from genalpha.admissions where id = v_admission;
  if v_member is null then raise exception 'approval did not create a member'; end if;

  select d.age into v_age
    from genalpha.student_details d where d.member_id = v_member;
  if v_age is null then
    raise exception 'student_details.age is null — approve_admission dropped the age';
  end if;
  if v_age <> 11 then
    raise exception 'student_details.age is %, expected 11', v_age;
  end if;

  -- ---------- and the roster the apps read must not carry a null ----------
  select s.age into v_roster
    from genalpha.students s where s.name = 'ZZ Age Only Probe';
  if v_roster is null then
    raise exception 'the roster shows a null age — this is what stopped the app loading';
  end if;
  if v_roster <> 11 then
    raise exception 'the roster shows age %, expected 11', v_roster;
  end if;

  -- ---------- a date of birth and no age still works ----------
  insert into genalpha.admissions (
    applicant_name, nationality, date_of_birth, age, gender,
    father_guardian_name, parent_contact_no, emergency_contact_no,
    school_college, address, time_slot, join_date, fees_paid, amount_paid,
    fee_plan, consent_accepted, terms_accepted)
  values ('ZZ Dob Only Probe', 'INDIAN', '2016-08-24', null, 'M',
          'Probe Parent', '9000000923', '9000000924',
          'Probe School', 'Probe Address', '6AM', date '2026-08-24', false, 0,
          'monthly', true, true)
  returning id into v_admission;

  perform genalpha.approve_admission(v_admission, 'test harness', '');
  select s.age into v_roster from genalpha.students s where s.name = 'ZZ Dob Only Probe';
  if v_roster is distinct from 10 then
    raise exception 'a date-of-birth-only admission reads age %, expected 10',
      coalesce(v_roster::text, 'null');
  end if;

  raise notice 'OK: an age, a date of birth, or either one alone all survive approval';
end $$;
