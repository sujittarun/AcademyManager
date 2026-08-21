-- Rejoin billing, driven through genalpha.student_payments — the view the
-- apps insert into — so record_fee_payment runs for real. Rolled back.

do $$
declare
  v_id uuid; v_member bigint; v_enroll bigint;
  v_from date; v_to date; v_renew date; v_err text;
begin
  insert into genalpha.students (name, age, time_slot, join_date, fees_paid, amount_paid,
                                 fee_plan, father_guardian_name, parent_contact_no, added_by)
  values ('ZZ Anchor Probe', 11, '6AM', '2026-01-10', true, 3500,
          'monthly', 'Probe Parent', '9000000912', 'test harness')
  returning id into v_id;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_id;

  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                           joined_on, renewal_on, status)
  values ('genalpha', v_member,
          (select id from centres where tenant_id='genalpha' order by id limit 1),
          'cricket', 1, '2026-01-10', '2026-02-10', 'active')
  returning id into v_enroll;

  -- ---------- 1. Dhruvan's case: rejoin 17th, pay 20th ----------
  update genalpha.students
     set discontinued = false, discontinued_at = null, rejoined_at = '2026-08-17'
   where id = v_id;
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, recorded_by)
  values (v_id, 'renewal', 'monthly', '2026-08-17', 1, 3500, '2026-08-20', 'test');

  select period_from, period_to into v_from, v_to
    from payments where enrollment_id = v_enroll and kind='renewal' order by id desc limit 1;
  if v_from is null then raise exception '1. no payment was recorded'; end if;
  if v_from <> date '2026-08-17' then
    raise exception '1. cycle starts %, expected the rejoin date 2026-08-17', v_from;
  end if;
  if v_to <> date '2026-09-17' then
    raise exception '1. next fee due %, expected 2026-09-17', v_to;
  end if;

  -- ---------- 2. The SECOND fee after a return is ordinary again ----------
  -- Due 17 Sep, paid late on 25 Sep: the ordinary rule applies and the player
  -- is not billed for the days they let lapse.
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, recorded_by)
  -- A different amount, because student_payments_write refuses an identical
  -- one inside two minutes — the guard that stopped Ayaan Bejugam's three
  -- renewals in sixty seconds.
  values (v_id, 'renewal', 'monthly', '2026-09-17', 1, 3600, '2026-09-25', 'test');
  select period_from into v_from
    from payments where enrollment_id = v_enroll and kind='renewal' order by id desc limit 1;
  if v_from <> date '2026-09-25' then
    raise exception '2. second fee starts %, expected the pay date 2026-09-25 — the rejoin anchor leaked into later renewals', v_from;
  end if;

  raise notice 'OK: rejoin billing scenarios hold';
end $$;

-- ---------- 3. The guards on the new parameter ----------
do $$
declare v_enroll bigint; v_member bigint; v_id uuid; v_ok boolean := false;
begin
  insert into genalpha.students (name, age, time_slot, join_date, fees_paid, amount_paid,
                                 fee_plan, father_guardian_name, parent_contact_no, added_by)
  values ('ZZ Guard Probe', 11, '6AM', '2026-01-10', true, 3500,
          'monthly', 'Probe Parent', '9000000913', 'test harness')
  returning id into v_id;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_id;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                           joined_on, renewal_on, status)
  values ('genalpha', v_member,
          (select id from centres where tenant_id='genalpha' order by id limit 1),
          'cricket', 1, '2026-01-10', '2026-06-01', 'active')
  returning id into v_enroll;

  perform record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal',
                             date '2026-06-01', null, 'paid', 'test', null, null);

  -- Overlapping coverage already sold must be refused.
  begin
    perform record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal',
                               date '2026-07-10', null, 'paid', 'test', null, date '2026-06-15');
  exception when check_violation then v_ok := true;
  end;
  if not v_ok then raise exception '3. an overlapping cycle start was accepted'; end if;

  -- A cycle that starts after the money must be refused.
  v_ok := false;
  begin
    perform record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal',
                               date '2026-07-10', null, 'paid', 'test', null, date '2026-08-01');
  exception when check_violation then v_ok := true;
  end;
  if not v_ok then raise exception '3. a cycle starting after its payment was accepted'; end if;

  raise notice 'OK: both guards on the cycle start hold';
end $$;
