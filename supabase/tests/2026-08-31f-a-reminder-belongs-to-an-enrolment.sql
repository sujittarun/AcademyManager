-- A reminder written through the GenAlpha view must carry its enrolment, and a
-- payment must then close it. Rolled back by run-test.sh.

do $$
declare
  v_id uuid; v_member bigint; v_enroll bigint; v_centre bigint;
  v_link bigint; v_status text; v_ist date; v_blocked boolean := false;
begin
  select id into v_centre from centres where tenant_id = 'genalpha' order by id limit 1;

  insert into genalpha.students (name, age, time_slot, join_date, fees_paid, amount_paid,
                                 fee_plan, father_guardian_name, parent_contact_no, added_by)
  values ('ZZ Enrolment Link Probe', 10, '6AM', '2026-07-01', true, 3500,
          'monthly', 'Probe Parent', '9000000931', 'test harness')
  returning id into v_id;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_id;

  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                           joined_on, renewal_on, status)
  values ('genalpha', v_member, v_centre, 'cricket', 1, '2026-07-01', '2026-08-01', 'active')
  returning id into v_enroll;

  -- ---------- 1. A reminder written through the view carries its enrolment ----------
  insert into genalpha.reminder_events (student_id, reminder_type, stage, status,
                                        due_date, parent_phone, created_by)
  values (v_id, 'renewal', 'due', 'sent', '2026-08-01', '9000000931', 'test harness');

  select enrollment_id, ist_date into v_link, v_ist
    from reminder_events where member_id = v_member order by id desc limit 1;
  if v_link is null then
    raise exception '1. the reminder was written with no enrolment — nothing can close it';
  end if;
  if v_link <> v_enroll then
    raise exception '1. the reminder points at enrolment %, expected %', v_link, v_enroll;
  end if;

  -- ---------- 2. ist_date is the IST day, not the UTC one ----------
  if v_ist <> (now() at time zone 'Asia/Kolkata')::date then
    raise exception '2. ist_date is %, expected the IST day %', v_ist,
      (now() at time zone 'Asia/Kolkata')::date;
  end if;

  -- ---------- 3. A payment now closes it ----------
  -- This is the whole point: before this migration apply_payment_coverage
  -- matched on enrollment_id and could never find a GenAlpha row.
  perform record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal', date '2026-08-01');

  select status into v_status
    from reminder_events where member_id = v_member order by id desc limit 1;
  if v_status <> 'resolved' then
    raise exception '3. the reminder is still %, expected resolved after payment', v_status;
  end if;

  -- ---------- 4. The one-per-day guard is armed again ----------
  begin
    insert into reminder_events (tenant_id, member_id, enrollment_id, reminder_type, stage,
                                 channel, status, due_date, overdue_days, retry_count,
                                 dry_run, sent_by, ist_date)
    values ('genalpha', v_member, v_enroll, 'renewal', 'due', 'whatsapp', 'queued',
            '2026-09-01', 0, 0, false, 'test', (now() at time zone 'Asia/Kolkata')::date);
    insert into reminder_events (tenant_id, member_id, enrollment_id, reminder_type, stage,
                                 channel, status, due_date, overdue_days, retry_count,
                                 dry_run, sent_by, ist_date)
    values ('genalpha', v_member, v_enroll, 'renewal', 'due', 'whatsapp', 'queued',
            '2026-09-01', 0, 0, false, 'test', (now() at time zone 'Asia/Kolkata')::date);
  exception when unique_violation then v_blocked := true;
  end;
  if not v_blocked then
    raise exception '4. two reminders for one enrolment on one day were accepted';
  end if;

  raise notice 'OK: reminders carry their enrolment, payments close them, one per day holds';
end $$;
