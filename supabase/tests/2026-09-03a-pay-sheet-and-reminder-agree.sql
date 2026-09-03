/* The sheet and the reminder must quote ONE number, and the plan must
   multiply it. Run after the migration, inside the rolled-back
   transaction run-test.sh provides. */

do $$
declare
  v_bad int; v_enrol bigint; v_mid bigint;
  v_sheet numeric; v_queue numeric;
begin
  ---------------------------------------------------------------- 1
  -- NOBODY OUTSIDE MEZZO IS PRICED FROM A PAYMENT.
  -- enrollment_fee() is called by Raj's iOS and Android clients, which
  -- cannot be force-updated; if this ever fails, those apps are already
  -- quoting a different number than they were built against.
  select count(*) into v_bad
    from enrollments e
   where e.tenant_id <> 'mezzo' and e.status = 'active'
     and enrollment_fee(e.id)->>'source' = 'last_paid';
  if v_bad <> 0 then
    raise exception '% enrolments outside mezzo are priced from a payment', v_bad;
  end if;

  ---------------------------------------------------------------- 2
  -- THE SHEET AND THE REMINDER AGREE, family by family. This is the
  -- whole point: one of them quoting 2,500 while the other opens on
  -- 1,500 is what produced thirteen cancelled payments.
  select count(*) into v_bad
    from reminder_queue('mezzo') q
   where (enrollment_fee(q.enrollment_id, q.months)->>'amount')::numeric
         is distinct from q.amount;
  if v_bad <> 0 then
    raise exception '% mezzo families would see one number on the sheet and another in the reminder', v_bad;
  end if;

  ---------------------------------------------------------------- 3
  -- THE PLAN MULTIPLIES THE RATE.
  -- Every Mezzo enrolment is on a one-month plan, so nothing in the
  -- live data can tell a rate from a rate-times-months. Built here.
  select e.id, e.member_id into v_enrol, v_mid
    from enrollments e
   where e.tenant_id='mezzo' and e.status='active'
     and not exists (select 1 from payments p
                      where p.tenant_id='mezzo' and p.enrollment_id = e.id
                        and p.status <> 'void')
   order by e.id limit 1;
  if v_enrol is null then
    raise exception 'no unpaid mezzo enrolment to build the plan case on';
  end if;

  insert into payments (tenant_id, member_id, enrollment_id, amount, months,
                        on_date, mode, kind, status)
  values ('mezzo', v_mid, v_enrol, 2000, 1, ist_today() - 10, 'UPI', 'renewal', 'paid');

  if (enrollment_fee(v_enrol, 1)->>'amount')::numeric <> 2000 then
    raise exception 'one month of a 2,000 rate is %', (enrollment_fee(v_enrol,1)->>'amount');
  end if;
  if (enrollment_fee(v_enrol, 3)->>'amount')::numeric <> 6000 then
    raise exception 'three months of a 2,000 rate is %, expected 6000',
      (enrollment_fee(v_enrol,3)->>'amount');
  end if;
  if (enrollment_fee(v_enrol, 12)->>'amount')::numeric <> 24000 then
    raise exception 'a year of a 2,000 rate is %, expected 24000',
      (enrollment_fee(v_enrol,12)->>'amount');
  end if;

  ---------------------------------------------------------------- 4
  -- AND THE REMINDER MULTIPLIES IT TOO, for an enrolment on a plan.
  update enrollments set plan_months = 3, renewal_on = ist_today() - 5
   where id = v_enrol;

  select q.amount into v_queue from reminder_queue('mezzo') q
   where q.enrollment_id = v_enrol;
  if v_queue is distinct from 6000 then
    raise exception 'a three-month plan at a 2,000 rate is chased for %, expected 6000',
      coalesce(v_queue::text,'null');
  end if;

  select (enrollment_fee(v_enrol)->>'amount')::numeric into v_sheet;
  if v_sheet is distinct from v_queue then
    raise exception 'the sheet says % and the reminder says %', v_sheet, v_queue;
  end if;

  ---------------------------------------------------------------- 5
  -- AN ADMISSION FEE STILL SETS NOTHING.
  insert into payments (tenant_id, member_id, enrollment_id, amount, months,
                        on_date, mode, kind, status)
  values ('mezzo', v_mid, v_enrol, 30000, 1, ist_today(), 'UPI', 'admission', 'paid');
  if (enrollment_fee(v_enrol, 1)->>'amount')::numeric <> 2000 then
    raise exception 'a 30,000 admission fee became the monthly rate on the sheet (%)',
      (enrollment_fee(v_enrol,1)->>'amount');
  end if;

  raise notice 'all five hold';
end $$;
