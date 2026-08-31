-- ============================================================
-- 2026-08-31a · One payment bought one month, not two
-- scope: shared
--
-- Veekshith D showed a next fee due of 23 Oct 2026 when the owner expected
-- September. He was carrying a free month, and the timeline says where it
-- came from — the SAME ₹3,500 renewal recorded twice on 21 July, ten minutes
-- apart:
--
--   17:36  Renewal fee paid  Rs 3500 • monthly • 1 month • cycle from 2026-07-23
--          "Monthly renewed from 23rd Jul 2026 to 23rd Aug 2026"
--   17:46  Renewal fee paid  Rs 3500 • monthly • 1 month • cycle from 2026-08-23
--          "Confirmed conversational renewal"
--
-- The second is the WhatsApp confirmation of the first, not a second payment,
-- and it rolled the cycle forward a month. Checked before touching anything:
-- exactly ONE ₹3,500 payment row exists for July, and ₹11,000 has been
-- received in total (4,000 joining + 3,500 + 3,500) against a 23 June join on
-- a monthly plan. Three months from 23 June ends 23 September.
--
-- This predates the duplicate guard in student_payments_write, which refuses
-- an identical amount inside two minutes. Ten minutes apart would still pass
-- it; widening that window is a judgement about legitimate same-day payments
-- and is deliberately NOT made here.
--
-- The 23rd is his billing anniversary and is preserved. Replaying the current
-- rule literally would have started the August payment on the day it was made
-- (31 Aug) and moved his renewal date permanently off the 23rd, which is not
-- what was asked for and not what the parent paid for.
--
-- shreyas k has the same double-recorded shape on 18 June (₹2,500, cycle
-- moved 18 Jun -> 11 Jun) but in the opposite direction: it REDUCED his
-- coverage, he is discontinued, and which of the two dates is the correction
-- cannot be told from the record. Left alone, and reported, rather than
-- guessed at.
-- ============================================================

do $$
declare
  v_enroll   bigint;
  v_july     bigint;
  v_august   bigint;
  v_received numeric;
begin
  select e.id into v_enroll
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.name = 'Veekshith D';
  if v_enroll is null then raise exception 'Veekshith D has no enrolment'; end if;

  -- Prove the premise before acting on it: one July payment, ₹11,000 total.
  select count(*), sum(amount) into v_received, v_received
    from payments where enrollment_id = v_enroll and status <> 'void';

  select sum(amount) into v_received
    from payments where enrollment_id = v_enroll and status <> 'void';
  if v_received <> 11000 then
    raise exception 'expected ₹11,000 received, found ₹% — do not correct blind', v_received;
  end if;

  select id into v_july from payments
   where enrollment_id = v_enroll and kind = 'renewal' and status <> 'void'
     and on_date between date '2026-07-01' and date '2026-07-31';
  if v_july is null then raise exception 'no July renewal to correct'; end if;

  select id into v_august from payments
   where enrollment_id = v_enroll and kind = 'renewal' and status <> 'void'
     and on_date between date '2026-08-01' and date '2026-08-31';
  if v_august is null then raise exception 'no August renewal to correct'; end if;

  -- Joining covered 23 Jun - 23 Jul, so the two renewals follow it in turn.
  update payments set period_from = date '2026-07-23', period_to = date '2026-08-23'
   where id = v_july;
  update payments set period_from = date '2026-08-23', period_to = date '2026-09-23'
   where id = v_august;

  update enrollments set renewal_on = date '2026-09-23', updated_at = now()
   where id = v_enroll;

  -- The tenant's own echo of the cycles, which the apps read as `renewals`.
  update genalpha.student_details d
     set renewals = '["2026-07-23", "2026-08-23"]'::jsonb
    from members m
   where m.id = d.member_id and m.tenant_id = 'genalpha' and m.name = 'Veekshith D';
end $$;

do $$
declare v_due date; v_through date; v_months int;
begin
  select e.renewal_on into v_due
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.name = 'Veekshith D';
  if v_due <> date '2026-09-23' then
    raise exception 'Veekshith next fee due is %, expected 2026-09-23', v_due;
  end if;

  select genalpha.student_paid_through_date(s.id) into v_through
    from genalpha.students s where s.name = 'Veekshith D';
  if v_through <> date '2026-09-23' then
    raise exception 'paid_through reads %, expected 2026-09-23', v_through;
  end if;

  -- Three payments, three months, no gaps and no overlaps from the join date.
  select count(*) into v_months
    from payments p join enrollments e on e.id = p.enrollment_id
    join members m on m.id = e.member_id
   where m.tenant_id = 'genalpha' and m.name = 'Veekshith D'
     and p.status <> 'void' and p.period_to is not null;
  if v_months <> 2 then
    raise exception 'expected 2 dated renewal periods, found %', v_months;
  end if;

  raise notice 'Veekshith D: 3 months paid from 23 Jun, due again 23 Sep';
end $$;
