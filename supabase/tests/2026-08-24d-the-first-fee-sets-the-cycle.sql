do $$
declare c bigint; m bigint; e bigint; f date; t date;
begin
  select id into c from centres where tenant_id='mezzo' limit 1;

  -- D1: THE REQUIREMENT. An existing student entered today, fee dated 20 Aug.
  insert into members (tenant_id,name,status) values ('mezzo','ZZ D1','active') returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',m,c,'Keyboard',1,'2026-08-24','2026-08-24','active') returning id into e;
  perform record_fee_payment('mezzo', e, 1500, 1, 'UPI', 'renewal', '2026-08-20');
  select period_from, period_to into f,t from payments where enrollment_id=e;
  if (f,t) is distinct from (date '2026-08-20', date '2026-09-20') then
    raise exception 'D1 backfilled student: got % -> %, wanted the payment day 2026-08-20', f, t;
  end if;

  -- D2: and the SECOND fee must go back to chaining — paying late must not
  -- move the cycle, which is the whole of requirement 2.
  perform record_fee_payment('mezzo', e, 1500, 1, 'UPI', 'renewal', '2026-09-29');   -- 9 days late
  select period_from, period_to into f,t from payments where enrollment_id=e order by id desc limit 1;
  if (f,t) is distinct from (date '2026-09-20', date '2026-10-20') then
    raise exception 'D2 the second fee re-anchored to the payment day: % -> %', f, t;
  end if;

  -- D3: a joining fee buys no months, so it must NOT count as the first fee
  insert into members (tenant_id,name,status) values ('mezzo','ZZ D3','active') returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',m,c,'Piano',1,'2026-08-24','2026-08-24','active') returning id into e;
  -- months null + kind 'admission' is how the function is told a joining fee
  -- buys no time; passing 0 trips the 1/3/6/12 plan guard.
  perform record_fee_payment('mezzo', e, 500, null, 'Cash', 'admission', '2026-08-18');
  perform record_fee_payment('mezzo', e, 2500, 1, 'UPI', 'renewal', '2026-08-20');
  select period_from, period_to into f,t from payments
    where enrollment_id=e and coalesce(months,0) > 0;
  if (f,t) is distinct from (date '2026-08-20', date '2026-09-20') then
    raise exception 'D3 a joining fee was mistaken for the first cycle fee: % -> %', f, t;
  end if;

  -- D4: a voided first fee must not count either
  insert into members (tenant_id,name,status) values ('mezzo','ZZ D4','active') returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',m,c,'Guitar',1,'2026-08-24','2026-08-24','active') returning id into e;
  perform record_fee_payment('mezzo', e, 1500, 1, 'UPI', 'renewal', '2026-08-22');
  perform void_payment('mezzo', (select id from payments where enrollment_id=e order by id desc limit 1), 'mistake');
  perform record_fee_payment('mezzo', e, 1500, 1, 'UPI', 'renewal', '2026-08-19');
  select period_from, period_to into f,t from payments
    where enrollment_id=e and status <> 'void';
  if (f,t) is distinct from (date '2026-08-19', date '2026-09-19') then
    raise exception 'D4 a cancelled fee still counted as the first: % -> %', f, t;
  end if;

  raise notice 'first-fee blocks passed';
end $$;

-- the other tenants must still bill a FIRST fee from the payment date too,
-- because that is what greatest(renewal_on, paid_on) already did for them
do $$
declare c bigint; m bigint; e bigint; f date;
begin
  select id into c from centres where tenant_id='genalpha' limit 1;
  if c is null then raise notice 'no genalpha centre; skipping'; return; end if;
  insert into members (tenant_id,name,status) values ('genalpha','ZZ blast d','active') returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('genalpha',m,c,'Cricket',1,'2026-03-24','2026-04-24','active') returning id into e;
  perform record_fee_payment('genalpha', e, 1000, 1, 'UPI', 'renewal', '2026-05-02');
  select period_from into f from payments where enrollment_id=e;
  if f <> date '2026-05-02' then
    raise exception 'BLAST RADIUS: genalpha moved. A late fee started % not 2026-05-02', f;
  end if;
  raise notice 'genalpha unchanged';
end $$;
