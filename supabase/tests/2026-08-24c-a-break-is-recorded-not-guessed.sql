do $$
declare
  v_centre bigint; v_mem bigint; v_enr bigint;
  v_ren date; v_rej date; v_st text; v_from date; v_to date; r jsonb;
begin
  select id into v_centre from centres where tenant_id='mezzo' order by id limit 1;

  -- B1: pausing moves NO money
  insert into members (tenant_id,name,status) values ('mezzo','ZZ B1','active') returning id into v_mem;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',v_mem,v_centre,'Keyboard',1,'2026-03-24','2026-04-24','active') returning id into v_enr;
  perform pause_enrollment('mezzo', v_enr, '2026-04-01');
  select status, renewal_on into v_st, v_ren from enrollments where id=v_enr;
  if v_st <> 'paused' then raise exception 'B1 status is %', v_st; end if;
  if v_ren <> date '2026-04-24' then
    raise exception 'B1 the pause moved the anchor to % — it must touch no date', v_ren;
  end if;

  -- B2: resuming 1.5 months later re-anchors to the return day, and records it
  r := resume_enrollment('mezzo', v_enr, '2026-05-15');
  select status, renewal_on into v_st, v_ren from enrollments where id=v_enr;
  select rejoined_at into v_rej from members where id=v_mem;
  if v_st <> 'active' then raise exception 'B2 status is %', v_st; end if;
  if v_ren <> date '2026-05-15' then raise exception 'B2 anchor is %, want 2026-10-15', v_ren; end if;
  -- IS DISTINCT FROM, not <>: a NULL rejoined_at makes <> evaluate to NULL and
  -- the guard never fires, which is exactly how this assertion first passed
  -- against a resume that recorded nothing.
  if v_rej is distinct from date '2026-05-15' then
    raise exception 'B2 the return date was not recorded: rejoined_at is %', v_rej;
  end if;
  if (r->>'days_written_off')::int <> 21 then
    raise exception 'B2 days written off = %, want 21', r->>'days_written_off';
  end if;

  -- B3: and the fee taken 3 days later still bills from the return day
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-05-18');
  select period_from, period_to into v_from, v_to from payments where enrollment_id=v_enr;
  if (v_from, v_to) is distinct from (date '2026-05-15', date '2026-06-15') then
    raise exception 'B3 cycle after the break: % -> %', v_from, v_to;
  end if;

  -- B4: the anchor never moves BACKWARDS
  insert into members (tenant_id,name,status) values ('mezzo','ZZ B4','active') returning id into v_mem;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',v_mem,v_centre,'Violin',1,'2026-03-24','2026-04-24','paused') returning id into v_enr;
  r := resume_enrollment('mezzo', v_enr, '2026-04-10');       -- back while still paid up
  select renewal_on into v_ren from enrollments where id=v_enr;
  if v_ren <> date '2026-04-24' then
    raise exception 'B4 coverage already paid for was resold: anchor moved to %', v_ren;
  end if;
  if (r->>'days_written_off')::int <> 0 then raise exception 'B4 wrote off days it should not'; end if;

  -- B5: a student who never formally paused can still be marked back
  insert into members (tenant_id,name,status) values ('mezzo','ZZ B5','active') returning id into v_mem;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',v_mem,v_centre,'Guitar',1,'2025-12-24','2026-04-24','active') returning id into v_enr;
  perform resume_enrollment('mezzo', v_enr, '2026-08-20');
  select renewal_on into v_ren from enrollments where id=v_enr;
  if v_ren <> date '2026-08-20' then raise exception 'B5 anchor is %', v_ren; end if;

  -- B6: guards
  begin perform pause_enrollment('mezzo', v_enr, '2099-01-01');
        raise exception 'B6 a break started in the future';
  exception when check_violation then null; end;

  insert into members (tenant_id,name,status) values ('mezzo','ZZ B6','active') returning id into v_mem;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',v_mem,v_centre,'Drums',1,'2026-03-24','2026-04-24','paused') returning id into v_enr;
  begin perform pause_enrollment('mezzo', v_enr);
        raise exception 'B6 paused twice';
  exception when check_violation then null; end;

  -- B7: a pending fee blocks the resume rather than being silently voided
  insert into members (tenant_id,name,status) values ('mezzo','ZZ B7','active') returning id into v_mem;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',v_mem,v_centre,'Keyboard',1,'2026-03-24','2026-04-24','active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-04-20', null, 'pending_verification');
  begin perform resume_enrollment('mezzo', v_enr, '2026-06-20');
        raise exception 'B7 the resume stepped over a fee waiting to be confirmed';
  exception when check_violation then null; end;

  -- B8: ids are global — another academy cannot reach a mezzo enrolment
  begin perform pause_enrollment('raj', v_enr);
        raise exception 'B8 cross-tenant reach';
  exception when no_data_found then null; end;

  raise notice 'break blocks passed';
end $$;
