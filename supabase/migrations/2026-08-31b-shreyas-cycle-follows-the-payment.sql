-- ============================================================
-- 2026-08-31b · shreyas k's cycle follows the payment that bought it
-- scope: shared
--
-- Same double-recorded shape as Veekshith D (2026-08-31a), the other way
-- round. On 18 June a ₹2,500 renewal was written twice, eighteen minutes
-- apart, and the second moved the cycle BACKWARD:
--
--   23:28  cycle from 2026-06-18
--   23:45  cycle from 2026-06-11
--
-- The payment was taken on 18 June, so that is where its month starts. The
-- 11th belongs to no payment and shortened his coverage by a week.
--
-- He is discontinued, so nothing downstream reads these dates — this is
-- tidying the record straight, not changing what anyone is owed or owes.
-- ============================================================

do $$
declare v_enroll bigint; v_pay bigint; v_amount numeric;
begin
  select e.id into v_enroll
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.name = 'shreyas k';
  if v_enroll is null then raise exception 'shreyas k has no enrolment'; end if;

  select id, amount into v_pay, v_amount
    from payments where enrollment_id = v_enroll and status <> 'void' and kind = 'renewal';
  if v_pay is null then raise exception 'no renewal to correct'; end if;
  if v_amount <> 2500 then
    raise exception 'expected a ₹2,500 renewal, found ₹% — do not correct blind', v_amount;
  end if;

  update payments
     set period_from = date '2026-06-18', period_to = date '2026-07-18'
   where id = v_pay;

  update enrollments set renewal_on = date '2026-07-18', updated_at = now()
   where id = v_enroll;

  update genalpha.student_details d
     set renewals = '["2026-06-18"]'::jsonb
    from members m
   where m.id = d.member_id and m.tenant_id = 'genalpha' and m.name = 'shreyas k';
end $$;

do $$
declare v_from date; v_to date; v_due date; v_status text;
begin
  select p.period_from, p.period_to, e.renewal_on, m.status
    into v_from, v_to, v_due, v_status
    from members m join enrollments e on e.member_id = m.id
    join payments p on p.enrollment_id = e.id and p.status <> 'void' and p.kind = 'renewal'
   where m.tenant_id = 'genalpha' and m.name = 'shreyas k';

  if v_from <> date '2026-06-18' or v_to <> date '2026-07-18' then
    raise exception 'shreyas cycle reads % .. %, expected 2026-06-18 .. 2026-07-18', v_from, v_to;
  end if;
  if v_due <> date '2026-07-18' then
    raise exception 'shreyas next fee due reads %, expected 2026-07-18', v_due;
  end if;
  -- He must stay discontinued: this migration tidies dates, nothing else.
  if v_status <> 'discontinued' then
    raise exception 'shreyas status is % — this migration must not revive him', v_status;
  end if;

  raise notice 'shreyas k: cycle 18 Jun - 18 Jul, still discontinued';
end $$;
