do $$
declare c bigint; m bigint; e bigint; j date; r date; res jsonb;
begin
  select id into c from centres where tenant_id='mezzo' limit 1;

  -- F1: nothing paid yet — the cycle follows the joining day
  insert into members (tenant_id,name,status) values ('mezzo','ZZ F1','active') returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('mezzo',m,c,'Keyboard',1,'2026-08-24','2026-08-24','active') returning id into e;
  res := set_joining_date('mezzo', e, '2026-06-24');
  select joined_on, renewal_on into j,r from enrollments where id=e;
  if (j,r) is distinct from (date '2026-06-24', date '2026-06-24') then
    raise exception 'F1 unpaid student: joined % renewal % — both should move', j, r;
  end if;

  -- F2: and the first fee then runs from the day it was paid, not from joining
  perform record_fee_payment('mezzo', e, 1500, 1, 'UPI', 'renewal', '2026-07-01');
  if (select period_from from payments where enrollment_id=e) <> date '2026-07-01' then
    raise exception 'F2 the first fee did not run from the payment day';
  end if;

  -- F3: once a fee is taken, correcting the joining day must NOT move the cycle
  select renewal_on into r from enrollments where id=e;
  res := set_joining_date('mezzo', e, '2026-05-01');
  select joined_on, renewal_on into j from enrollments where id=e;
  if j <> date '2026-05-01' then raise exception 'F3 the joining day did not move'; end if;
  if (select renewal_on from enrollments where id=e) <> r then
    raise exception 'F3 correcting a date re-billed a paid student: renewal moved to %',
      (select renewal_on from enrollments where id=e);
  end if;
  if (res->>'fees_taken')::int <> 1 then raise exception 'F3 fees_taken is %', res->>'fees_taken'; end if;

  -- F4: guards
  begin perform set_joining_date('mezzo', e, '2099-01-01');
        raise exception 'F4 a future joining date was accepted';
  exception when check_violation then null; end;
  begin perform set_joining_date('mezzo', e, null);
        raise exception 'F4 a null joining date was accepted';
  exception when check_violation then null; end;
  begin perform set_joining_date('raj', e, '2026-05-01');
        raise exception 'F4 cross-tenant reach';
  exception when no_data_found then null; end;

  raise notice 'joining-date blocks passed';
end $$;
