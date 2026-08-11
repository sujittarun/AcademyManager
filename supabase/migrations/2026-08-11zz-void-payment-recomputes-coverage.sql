-- ============================================================
-- 2026-08-11zz · Voiding a payment did not take the coverage back
-- scope: shared
--
-- Found on a live row. Player F had three renewals recorded in a
-- minute and two of them deleted; enrollments.renewal_on stayed at
-- 2026-11-11 with only one payment surviving. The academy's screen said
-- paid through November for a family who had paid one month.
--
-- void_payment() sets status='void' and writes a timeline note. That is
-- all it has ever done. record_fee_payment() rolls renewal_on FORWARD and
-- nothing rolls it back, so every voided payment permanently overstates a
-- family's coverage and quietly removes them from reminder_queue().
--
-- This is a shared function: raj is exposed to it too, and its 9 reminder
-- rows and 96 payments run through the same path.
--
-- THE FIX IS AN EXACT UNDO, not a recompute, and the first draft got that
-- wrong in a way worth recording.
--
-- Recomputing renewal_on as max(period_to) over surviving paid payments
-- reads well and fails on this data: renewal_on was seeded at the merge
-- from GenAlpha's own student_paid_through_date(), and many migrated
-- payments have period_to null. The probe below caught it immediately —
-- voiding a probe payment moved a real enrollment from 2026-08-23 back to
-- 2026-07-23, because the recompute could only see the payments that
-- happen to carry an end date. Applied broadly that would have made
-- paid-up families look overdue and started chasing them.
--
-- So: undo exactly this payment's contribution, and only when this
-- payment is the one that set the current value. renewal_on = period_to
-- means this payment is the tail, and period_from is what it was before.
-- Anything else is left alone, because a later payment already covers it.
-- ============================================================

create or replace function public.void_payment(
  p_tenant text, p_payment bigint, p_reason text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare p payments; v_before date; v_after date;
begin
  perform assert_staff_or_service(p_tenant);
  select * into p from payments where id = p_payment and tenant_id = p_tenant;
  if not found then raise exception 'Payment not found.' using errcode = 'no_data_found'; end if;

  update payments set status = 'void', note = coalesce(p_reason, note) where id = p.id;

  -- Take the coverage back. Only meaningful for a payment that bought
  -- time on an enrollment; a jersey or an admission fee with no months
  -- never moved renewal_on and must not move it now.
  if p.enrollment_id is not null and coalesce(p.months, 0) > 0 then
    select renewal_on into v_before from enrollments where id = p.enrollment_id;

    update enrollments e
       set renewal_on = p.period_from
     where e.id = p.enrollment_id
       and e.tenant_id = p_tenant
       and p.period_to is not null
       and p.period_from is not null
       and e.renewal_on = p.period_to;

    select renewal_on into v_after from enrollments where id = p.enrollment_id;
  end if;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, p.member_id, p.enrollment_id, 'note', 'Payment voided',
          coalesce(p_reason, 'Recorded in error'),
          jsonb_build_object('payment_id', p.id, 'amount', p.amount,
                             'changed_by', p.collected_by,
                             'renewal_on_before', v_before,
                             'renewal_on_after', v_after));
end $$;

comment on function public.void_payment(text, bigint, text) is
  'Reverses a payment AND recomputes enrollments.renewal_on from what survives. Before 2026-08-11zz it only flipped the status, so every void left the family credited with coverage they no longer had.';

-- ------------------------------------------------------------
-- Repair the enrollments already overstated by past voids
-- ------------------------------------------------------------
-- Same exact-undo rule, walked from the newest void backwards, so a
-- family who had three payments voided has all three unwound in order
-- and nobody is pulled below what a surviving payment covers.
do $repair$
declare v record; moved int := 0;
begin
  for v in
    select p.id, p.enrollment_id, p.tenant_id, p.period_from, p.period_to
      from payments p
     where p.status = 'void' and coalesce(p.months,0) > 0
       and p.enrollment_id is not null
       and p.period_from is not null and p.period_to is not null
     order by p.period_to desc
  loop
    update enrollments e
       set renewal_on = v.period_from
     where e.id = v.enrollment_id and e.tenant_id = v.tenant_id
       and e.renewal_on = v.period_to;
    if found then moved := moved + 1; end if;
  end loop;
  raise notice 'unwound % voided payment(s) that were still counted as coverage', moved;
end $repair$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; n0 int; v_before date; v_after date; v_enroll bigint; v_pay bigint; v_member bigint;
begin
  -- No enrollment may still sit exactly on a VOIDED payment's end date:
  -- that is the signature of coverage never taken back.
  select count(*) into n
    from enrollments e
    join payments v on v.enrollment_id = e.id and v.tenant_id = e.tenant_id
   where v.status = 'void' and coalesce(v.months,0) > 0
     and e.renewal_on = v.period_to;
  if n <> 0 then raise exception '% enrollments still credited by a voided payment', n; end if;

  -- Exercise it: record, then void, and the date must come back.
  -- Counted, not hardcoded — real payments land while this is being
  -- written, and a stale literal fails for the wrong reason.
  select count(*) into n0 from payments where tenant_id='genalpha';
  select e.id, e.member_id into v_enroll, v_member
    from enrollments e where e.tenant_id='genalpha' and e.renewal_on is not null
    order by e.id limit 1;
  select renewal_on into v_before from enrollments where id = v_enroll;

  v_pay := (record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal',
                               ist_today(), null, 'paid', 'zz-probe', 'void probe')->>'payment_id')::bigint;
  select renewal_on into v_after from enrollments where id = v_enroll;
  if v_after <= v_before then
    raise exception 'the probe payment did not move renewal_on (% -> %)', v_before, v_after;
  end if;

  perform void_payment('genalpha', v_pay, 'probe');
  select renewal_on into v_after from enrollments where id = v_enroll;
  if v_after is distinct from v_before then
    raise exception 'voiding did not restore renewal_on: % (expected %)', v_after, v_before;
  end if;
  raise notice 'void restores coverage: % -> forward -> % again', v_before, v_after;

  delete from member_timeline where member_id = v_member and at > now() - interval '2 minutes';
  delete from payments where id = v_pay;

  -- money unchanged by the probe
  select count(*) into n from payments where tenant_id='genalpha';
  if n <> n0 then raise exception 'the probe left % payment(s) behind', n - n0; end if;
end $$;
