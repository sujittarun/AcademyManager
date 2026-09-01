/* Proves the opt-in is an opt-IN: only the tenant that asked for it
   moves, and it moves for the right reason.

   Run inside the transaction run-test.sh rolls back, AFTER the
   migration has been applied to it. */

do $$
declare
  v_bad      int;
  v_changed  int;
  v_src      text;
  v_amt      numeric;
  v_rows     int;
begin
  ---------------------------------------------------------------- 1
  -- EVERY OTHER TENANT STILL RESOLVES FROM THE FEE CHAIN.
  -- Not "the totals look similar" — every single row's amount must
  -- still be the number resolve_fee() gives for that enrolment.
  select count(*) into v_bad
    from tenants t
    join lateral reminder_queue(t.id) q on true
    join enrollments e on e.id = q.enrollment_id
   where t.id <> 'mezzo'
     and q.amount is distinct from
         (resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport,
                      e.batch_id, e.plan_months, e.custom_amount)->>'amount')::numeric;
  if v_bad <> 0 then
    raise exception '% rows outside mezzo no longer quote the fee chain', v_bad;
  end if;

  select count(*) into v_bad
    from tenants t
    join lateral reminder_queue(t.id) q on true
   where t.id <> 'mezzo' and q.fee_source = 'last_paid';
  if v_bad <> 0 then
    raise exception '% rows outside mezzo are sourced from a payment', v_bad;
  end if;

  ---------------------------------------------------------------- 2
  -- THE QUEUE MEMBERSHIP DID NOT MOVE. Changing what a row costs must
  -- never change WHO is on the list; that is decided by days_since.
  select count(*) into v_rows from reminder_queue('raj');
  if v_rows <> 88 then
    raise exception 'raj queue is now % rows, was 88', v_rows;
  end if;
  select count(*) into v_rows from reminder_queue('demo');
  if v_rows <> 50 then
    raise exception 'demo queue is now % rows, was 50', v_rows;
  end if;
  select count(*) into v_rows from reminder_queue('genalpha');
  if v_rows <> 7 then
    raise exception 'genalpha queue is now % rows, was 7', v_rows;
  end if;
  select count(*) into v_rows from reminder_queue('mezzo');
  if v_rows <> 14 then
    raise exception 'mezzo queue is now % rows, was 14', v_rows;
  end if;

  ---------------------------------------------------------------- 3
  -- MEZZO QUOTES THE LAST MONTHLY RATE WHERE THERE IS ONE.
  select count(*) into v_changed
    from reminder_queue('mezzo') q
    join lateral (
      select round(p.amount / nullif(p.months,0), 2) monthly
        from payments p
       where p.tenant_id = 'mezzo' and p.status <> 'void'
         and p.enrollment_id = q.enrollment_id
         and coalesce(p.months,0) > 0
       order by p.on_date desc, p.id desc limit 1
    ) lp on true
   where q.amount is distinct from lp.monthly;
  if v_changed <> 0 then
    raise exception '% mezzo rows ignore what the family last paid', v_changed;
  end if;

  ---------------------------------------------------------------- 4
  -- A FAMILY THAT HAS NEVER PAID STILL FALLS BACK TO THE FEE CHAIN,
  -- and says so. Eleven of the fourteen currently in the queue are in
  -- this state, so a fallback that broke would be most of the list.
  select count(*) into v_bad
    from reminder_queue('mezzo') q
    join enrollments e on e.id = q.enrollment_id
   where not exists (select 1 from payments p
                      where p.tenant_id='mezzo' and p.status <> 'void'
                        and p.enrollment_id = q.enrollment_id
                        and coalesce(p.months,0) > 0)
     and (q.fee_source = 'last_paid'
          or q.amount is distinct from
             (resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport,
                          e.batch_id, e.plan_months, e.custom_amount)->>'amount')::numeric);
  if v_bad <> 0 then
    raise exception '% never-paid mezzo rows lost their fallback', v_bad;
  end if;

  ---------------------------------------------------------------- 5
  -- THE FAMILY THIS WAS WRITTEN FOR. Aarik pays 3,000 against a list
  -- price of 1,500; a test that only counted rows would pass with the
  -- old number still in the message.
  select q.amount, q.fee_source into v_amt, v_src
    from reminder_queue('mezzo') q
    join members m on m.id = q.member_id
   where m.name = 'Aarik';
  if v_amt is not null then
    if v_amt <> 3000 then
      raise exception 'Aarik is quoted %, expected 3000', v_amt;
    end if;
    if v_src <> 'last_paid' then
      raise exception 'Aarik''s 3000 is attributed to %, expected last_paid', v_src;
    end if;
  end if;

  ---------------------------------------------------------------- 6
  -- A TERM PAID UP FRONT IS A MONTHLY RATE, NOT THE LUMP.
  --
  -- Every one of Mezzo's sixty-three payments covers a single month, so
  -- nothing in the live data divides by anything and a wrong divisor
  -- would sit there silently until the first family paid for a term —
  -- and then ask them for three months' money every month. The case is
  -- built here instead, and run-test.sh rolls it back.
  declare
    v_enrol bigint;
    v_quote numeric;
  begin
    select q.enrollment_id into v_enrol
      from reminder_queue('mezzo') q
     where not exists (select 1 from payments p
                        where p.tenant_id='mezzo' and p.enrollment_id = q.enrollment_id
                          and p.status <> 'void')
     order by q.enrollment_id
     limit 1;

    if v_enrol is null then
      raise exception 'no unpaid mezzo enrolment to build the term case on';
    end if;

    insert into payments (tenant_id, member_id, enrollment_id, amount, months,
                          on_date, mode, kind, status)
    select 'mezzo', e.member_id, e.id, 5400, 3, ist_today(), 'UPI', 'renewal', 'paid'
      from enrollments e where e.id = v_enrol;

    select q.amount into v_quote from reminder_queue('mezzo') q
     where q.enrollment_id = v_enrol;

    if v_quote is distinct from 1800 then
      raise exception '5,400 paid over 3 months is quoted as %, expected 1800 a month',
        coalesce(v_quote::text, 'null');
    end if;
  end;

  ---------------------------------------------------------------- 7
  -- IT IS THE LATEST PAYMENT, NOT THE FIRST ONE.
  --
  -- No Mezzo enrolment has paid twice yet, so "first" and "last" are
  -- the same row in every piece of live data and a function reading the
  -- wrong end of the history looks perfectly correct. That is the whole
  -- point of the feature, though: when a family's rate changes, the
  -- reminder has to follow it. Two payments are built here to say so.
  declare
    v_enrol bigint;
    v_quote numeric;
    v_mid   bigint;
  begin
    select q.enrollment_id, q.member_id into v_enrol, v_mid
      from reminder_queue('mezzo') q
     where not exists (select 1 from payments p
                        where p.tenant_id='mezzo' and p.enrollment_id = q.enrollment_id
                          and p.status <> 'void')
     order by q.enrollment_id desc
     limit 1;

    if v_enrol is null then
      raise exception 'no unpaid mezzo enrolment to build the rate-change case on';
    end if;

    /* they used to pay 1,500 and were moved to 2,500 last month */
    insert into payments (tenant_id, member_id, enrollment_id, amount, months,
                          on_date, mode, kind, status)
    values ('mezzo', v_mid, v_enrol, 1500, 1, ist_today() - 60, 'UPI', 'renewal', 'paid'),
           ('mezzo', v_mid, v_enrol, 2500, 1, ist_today() - 30, 'UPI', 'renewal', 'paid');

    select q.amount into v_quote from reminder_queue('mezzo') q
     where q.enrollment_id = v_enrol;

    if v_quote is distinct from 2500 then
      raise exception 'a family moved from 1,500 to 2,500 is still quoted %, so the reminder is reading the oldest payment',
        coalesce(v_quote::text, 'null');
    end if;

    /* and a void must not become the rate: voiding the 2,500 puts them
       back on 1,500, not on nothing */
    update payments set status = 'void'
     where enrollment_id = v_enrol and amount = 2500 and tenant_id = 'mezzo';

    select q.amount into v_quote from reminder_queue('mezzo') q
     where q.enrollment_id = v_enrol;

    if v_quote is distinct from 1500 then
      raise exception 'after voiding the 2,500 the quote is %, expected the 1,500 before it',
        coalesce(v_quote::text, 'null');
    end if;
  end;

  raise notice 'all seven hold';
end $$;
