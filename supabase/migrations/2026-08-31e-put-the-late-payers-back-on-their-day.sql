-- ============================================================
-- 2026-08-31e · Put the late payers back on their own day
-- scope: shared
--
-- Three players paid late between 25 and 31 August, while record_fee_payment
-- still defaulted to anchoring a late renewal on the payment date
-- (2026-08-31d made 'due' the default). Each had their billing anniversary
-- pushed forward by the number of days they were late.
--
-- Every correction below is triangulated from three independent records that
-- agree, not from one:
--
--   PRANEET SINGURU  joined 21 May, pays on the 21st every month
--     payments      21 May admission, cycles from 21 Jun and 21 Jul
--     renewals echo 21 Jun, 21 Jul, 21 Aug   <- the tenant layer already
--                                               recorded 21 Aug as the start
--     reminders     due 2026-08-21 on the 19th, 21st and 24th
--     -> paid 25 Aug, so his month is 21 Aug - 21 Sep, not 25 Aug - 25 Sep
--
--   SYED ABDUL REHMAN  joined 16 Jul, cycle on the 16th
--     payments      16 Jul admission from 16 Jul
--     renewals echo 2026-08-16
--     reminders     due 2026-08-16, chased to manual_followup
--     -> paid 31 Aug, so 16 Aug - 16 Sep, not 31 Aug - 30 Sep
--
--   AADVIK M  joined 22 Jun, cycle on the 22nd
--     payments      22 Jun admission, cycle from 22 Jul
--     renewals echo 22 Jul, 22 Aug
--     reminders     due 2026-08-22
--     -> paid 31 Aug, so 22 Aug - 22 Sep, not 31 Aug - 30 Sep
--
-- MISHA DEWANGAN is deliberately NOT corrected. She joined 26 Aug and her
-- 28 Aug payment is her FIRST fee, which the chain rule anchors to its own
-- payment date on purpose — joined_on is the day someone was typed into the
-- app, and for a player who has been coming for months that is not when their
-- cycle starts. 28 Aug - 28 Sep is correct. She was named in error in the
-- report that preceded this migration.
--
-- Each update is guarded on the exact wrong value, so a second run or a state
-- that has since moved changes nothing.
-- ============================================================

do $$
declare
  v_fixed int := 0;
  r record;
begin
  for r in
    select * from (values
      ('Praneet Singuru',   5046, date '2026-08-25', date '2026-08-21', date '2026-09-21'),
      ('SYED ABDUL REHMAN', 5049, date '2026-08-31', date '2026-08-16', date '2026-09-16'),
      ('Aadvik M',          5052, date '2026-08-31', date '2026-08-22', date '2026-09-22')
    ) as t(name, pay_id, wrong_from, right_from, right_to)
  loop
    update payments p
       set period_from = r.right_from, period_to = r.right_to
     where p.id = r.pay_id
       and p.tenant_id = 'genalpha'
       and p.status <> 'void'
       and p.period_from = r.wrong_from;
    if found then
      v_fixed := v_fixed + 1;
      update enrollments e
         set renewal_on = r.right_to, updated_at = now()
        from payments p
       where p.id = r.pay_id and e.id = p.enrollment_id;
    else
      raise exception 'payment % for % does not start on %, refusing to guess',
        r.pay_id, r.name, r.wrong_from;
    end if;
  end loop;

  if v_fixed <> 3 then
    raise exception 'expected to correct 3 payments, corrected %', v_fixed;
  end if;
end $$;

do $$
declare r record; v_due date;
begin
  for r in
    select * from (values
      ('Praneet Singuru',   date '2026-09-21'),
      ('SYED ABDUL REHMAN', date '2026-09-16'),
      ('Aadvik M',          date '2026-09-22'),
      ('Misha Dewangan',    date '2026-09-28')   -- untouched, and must stay so
    ) as t(name, expected)
  loop
    select e.renewal_on into v_due
      from members m join enrollments e on e.member_id = m.id
     where m.tenant_id = 'genalpha' and m.name = r.name;
    if v_due <> r.expected then
      raise exception '% next fee due is %, expected %', r.name, v_due, r.expected;
    end if;
  end loop;

  -- Nobody may be left with a cycle that starts after the money arrived, which
  -- is the shape of the defect this closes.
  if exists (
    select 1 from payments p
     where p.tenant_id = 'genalpha' and p.status <> 'void' and p.kind <> 'custom'
       and p.period_from > p.on_date
       and p.created_at >= '2026-08-24 16:30:00+00'
       and p.period_to is not null
       and p.period_from > (select coalesce(max(prior.period_to), p.period_from)
                              from payments prior
                             where prior.enrollment_id = p.enrollment_id
                               and prior.status <> 'void' and prior.id <> p.id
                               and prior.period_to is not null)) then
    raise exception 'a payment still starts after both its money and the previous cycle';
  end if;

  raise notice 'Praneet, Syed and Aadvik are back on their own day; Misha unchanged';
end $$;
