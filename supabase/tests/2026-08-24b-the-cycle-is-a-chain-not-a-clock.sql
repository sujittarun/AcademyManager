-- ============================================================
-- Proves 2026-08-24b. Run with run-test.sh, which wraps the migration and
-- this file in one transaction and always rolls it back.
--
-- Every assertion drives the real record_fee_payment and reads period_from,
-- period_to and enrollments.renewal_on back. Exact dates, never "it moved".
-- ============================================================

do $$
declare
  v_centre bigint;
  v_mem bigint; v_enr bigint;
  v_from date; v_to date; v_ren date;
  v_msg text;
begin
  select id into v_centre from centres where tenant_id = 'mezzo' order by id limit 1;
  if v_centre is null then raise exception 'mezzo has no centre to enrol into'; end if;

  -- ---------- C1: joins and pays the same day ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C1','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Keyboard', 1, '2026-08-24', '2026-08-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-08-24');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  select renewal_on into v_ren from enrollments where id = v_enr;
  if (v_from, v_to, v_ren) is distinct from (date '2026-08-24', date '2026-09-24', date '2026-09-24') then
    raise exception 'C1 join+pay same day: got % -> %, renewal %', v_from, v_to, v_ren;
  end if;

  -- ---------- C2: joins 24 Aug, pays 27 Aug ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C2','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Keyboard', 1, '2026-08-24', '2026-08-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-08-27');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  -- 2026-08-24d: the FIRST fee sets the cycle, so it runs from the day the
  -- money arrived, not from the day he was typed into the app. That is the
  -- "payment day as the joining day" rule, and it is what makes backfilling
  -- an existing student work.
  if (v_from, v_to) is distinct from (date '2026-08-27', date '2026-09-27') then
    raise exception 'C2 first fee 3 days after joining: got % -> % (should run from the payment day)', v_from, v_to;
  end if;

  -- ---------- C3: backfilled student, joined 1 Jun, first fee 24 Aug ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C3','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Keyboard', 1, '2026-06-01', '2026-08-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-08-24');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  if (v_from, v_to) is distinct from (date '2026-08-24', date '2026-09-24') then
    raise exception 'C3 backfill: got % -> %', v_from, v_to;
  end if;

  -- ---------- C5: THE HEADLINE. due 24 Sep, pays 30 Sep ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C5','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Keyboard', 1, '2026-08-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-09-30');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  select renewal_on into v_ren from enrollments where id = v_enr;
  if (v_from, v_to, v_ren) is distinct from (date '2026-09-24', date '2026-10-24', date '2026-10-24') then
    raise exception 'C5 SIX DAYS LATE: got % -> %, renewal % (the lapse was gifted)', v_from, v_to, v_ren;
  end if;

  -- ---------- C6: due 24 Sep, pays 20 Sep (early) ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C6','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Keyboard', 1, '2026-08-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-09-20');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  if (v_from, v_to) is distinct from (date '2026-09-24', date '2026-10-24') then
    raise exception 'C6 paying early became a penalty: got % -> %', v_from, v_to;
  end if;

  -- ---------- C7: three months at once ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C7','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Piano', 3, '2026-08-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 7500, 3, 'UPI', 'renewal', '2026-09-24');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  if (v_from, v_to) is distinct from (date '2026-09-24', date '2026-12-24') then
    raise exception 'C7 three months: got % -> %', v_from, v_to;
  end if;

  -- ---------- C8: THE PAUSE SCENARIO. away 1 Sep, back 15 Oct, pays 18 Oct ----------
  insert into members (tenant_id, name, status, rejoined_at)
    values ('mezzo','ZZ C8','active','2026-10-15') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Violin', 1, '2026-07-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-10-18');
  select period_from, period_to, on_date into v_from, v_to, v_ren from payments where enrollment_id = v_enr;
  if (v_from, v_to) is distinct from (date '2026-10-15', date '2026-11-15') then
    raise exception 'C8 back from a break: cycle should start the day he returned, got % -> %', v_from, v_to;
  end if;
  if v_ren <> date '2026-10-18' then
    raise exception 'C8 the two clocks collapsed: on_date is %, should be the day he paid', v_ren;
  end if;

  -- ---------- C9: back and pays the same day ----------
  insert into members (tenant_id, name, status, rejoined_at)
    values ('mezzo','ZZ C9','active','2026-10-15') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Violin', 1, '2026-07-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-10-15');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  if (v_from, v_to) is distinct from (date '2026-10-15', date '2026-11-15') then
    raise exception 'C9 back and paid same day: got % -> %', v_from, v_to;
  end if;

  -- ---------- C10: the rejoin anchors ONCE; the next fee chains ----------
  insert into members (tenant_id, name, status, rejoined_at)
    values ('mezzo','ZZ C10','active','2026-10-15') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Violin', 1, '2026-07-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-10-15');
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-11-20');   -- 5 days late
  select period_from, period_to into v_from, v_to
    from payments where enrollment_id = v_enr order by id desc limit 1;
  if (v_from, v_to) is distinct from (date '2026-11-15', date '2026-12-15') then
    raise exception 'C10 second fee after a rejoin re-anchored instead of chaining: got % -> %', v_from, v_to;
  end if;

  -- ---------- C11: never formally paused, vanishes four months ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C11','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Guitar', 1, '2026-05-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2027-01-20');
  select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
  if (v_from, v_to) is distinct from (date '2026-09-24', date '2026-10-24') then
    raise exception 'C11 four-month absence with no recorded return: got % -> % (should chain, and stay owing)', v_from, v_to;
  end if;

  -- ---------- C12: a fee on a paused student is refused, for mezzo ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C12','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Drums', 1, '2026-08-24', '2026-09-24', 'paused') returning id into v_enr;
  begin
    perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-09-24');
    raise exception 'C12 a fee was taken against a paused student';
  exception when check_violation then null;
  end;

  -- ---------- C14: void is an exact undo ----------
  insert into members (tenant_id, name, status) values ('mezzo','ZZ C14','active') returning id into v_mem;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
    values ('mezzo', v_mem, v_centre, 'Keyboard', 1, '2026-08-24', '2026-09-24', 'active') returning id into v_enr;
  perform record_fee_payment('mezzo', v_enr, 1500, 1, 'UPI', 'renewal', '2026-09-30');
  perform void_payment('mezzo', (select id from payments where enrollment_id = v_enr order by id desc limit 1), 'test');
  select renewal_on into v_ren from enrollments where id = v_enr;
  if v_ren <> date '2026-09-24' then
    raise exception 'C14 void did not put the anchor back exactly: %', v_ren;
  end if;

  raise notice 'mezzo blocks passed';
end $$;

-- ============================================================
-- THE BLAST-RADIUS BLOCK. The most important assertions in the file:
-- every tenant that has NOT opted in must behave exactly as before, which
-- means a late fee still starts on the day it was paid.
-- ============================================================
do $$
declare
  v_centre bigint; v_mem bigint; v_enr bigint;
  v_from date; v_to date; t text;
begin
  foreach t in array array['raj','genalpha','demo'] loop
    select id into v_centre from centres where tenant_id = t order by id limit 1;
    if v_centre is null then
      raise notice 'skipping % — no centre', t; continue;
    end if;

    insert into members (tenant_id, name, status) values (t,'ZZ blast','active') returning id into v_mem;
    insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months, joined_on, renewal_on, status)
      values (t, v_mem, v_centre, 'Cricket', 1, '2026-08-24', '2026-09-24', 'active') returning id into v_enr;

    -- six days late, exactly the case that moves for mezzo
    perform record_fee_payment(t, v_enr, 1000, 1, 'UPI', 'renewal', '2026-09-30');
    select period_from, period_to into v_from, v_to from payments where enrollment_id = v_enr;
    if v_from <> date '2026-09-30' then
      raise exception 'BLAST RADIUS: % changed. A late fee started % — it must still start on the day it was paid.', t, v_from;
    end if;

    -- and a paused enrolment must still accept a fee for them
    update enrollments set status = 'paused' where id = v_enr;
    perform record_fee_payment(t, v_enr, 1000, 1, 'UPI', 'renewal', '2026-10-05');

    raise notice '% unchanged: late fee still anchors to the payment date', t;
  end loop;
end $$;

-- and the flag itself is on exactly one tenant
do $$
declare n int;
begin
  select count(*) into n from tenants where config->'fees'->>'lateAnchor' = 'due';
  if n <> 1 then raise exception '% tenants carry lateAnchor=due, expected exactly 1 (mezzo)', n; end if;
  select count(*) into n from tenants where id <> 'mezzo' and config ? 'fees';
  if n <> 0 then raise exception '% other tenant(s) grew a fees key', n; end if;
  raise notice 'the opt-in is on mezzo alone';
end $$;
