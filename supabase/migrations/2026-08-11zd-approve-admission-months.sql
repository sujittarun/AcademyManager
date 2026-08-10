-- ============================================================
-- 2026-08-11zd · approve_admission would recreate the money bug on every admission
-- scope: shared
--
-- 2026-08-11y hand-repaired two families whose entire plan total was
-- stored as their monthly fee. This is the function that produced them,
-- unchanged, waiting to do it again on the next approval.
--
-- Two defects, feeding each other, in 2026-08-10p:
--
--   plan_months = case when fee_plan='quarterly' then 3 else 1 end
--   monthly_amount = a.coaching_fee          -- a PLAN TOTAL
--
-- coaching_fee comes from the app's own price list (script.js:313-320):
-- quarterly 9975 = 3500*3*0.95, halfyearly 18900 = 3500*6*0.90. So:
--
--   quarterly  -> monthly_amount 9975 with plan_months 3.
--                 reminder_queue() quotes 29,925 for a quarter the app
--                 itself prices at 9,975.
--   halfyearly -> plan_months stays 1, so 18,900 becomes the family's
--                 MONTHLY rate and renewal_on is set one month out
--                 instead of six. Chased five months early, for six
--                 times the money. The app offers this plan and passes
--                 fee_plan through verbatim into an unconstrained text
--                 column.
--   special    -> the discounted total lands on a 1-month plan the same way.
--
-- Never edit 2026-08-10p: it is in the ledger, keyed on filename+sha256.
-- This replaces the function.
-- ============================================================

create or replace function genalpha.approve_admission(p_admission_id uuid, p_reviewed_by text DEFAULT 'Manager'::text, p_review_notes text DEFAULT ''::text)
 RETURNS TABLE(member_id bigint, reg_no bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  -- The plan length, resolved ONCE. The previous version asked
  -- "is it quarterly?" in two places and answered 1 for everything else,
  -- so a halfyearly admission got a one-month enrolment AND had its
  -- six-month total written as a monthly rate: chased five months early,
  -- for six times the money. The app offers halfyearly (index.html:849)
  -- and passes fee_plan through verbatim.
  v_months integer;
  v_special_months integer := 1; a genalpha.admissions%rowtype; v_member bigint; v_centre bigint; v_batch bigint;
begin
  perform assert_staff_or_service('genalpha');

  select * into a from genalpha.admissions where id = p_admission_id for update;
  if not found then raise exception 'Admission not found.'; end if;

  -- idempotent: approving twice returns the same child rather than making a second
  if a.review_status = 'approved' and a.approved_member_id is not null then
    return query select a.approved_member_id, a.reg_no;
    return;
  end if;

  select id into v_centre from public.centres where tenant_id='genalpha' order by id limit 1;
  if v_centre is null then raise exception 'genalpha has no centre — cannot enrol'; end if;
  select id into v_batch from public.batches
   where tenant_id='genalpha'
     and (a.time_slot is null or name ilike '%'||a.time_slot||'%')
   order by (name ilike '%'||coalesce(a.time_slot,'~')||'%') desc, id limit 1;

  insert into public.members (tenant_id, name, phone, parent_name, parent_phone, alt_phone,
                              school, grade, address, dob, gender, joined, status, program)
  values ('genalpha', a.applicant_name, a.parent_contact_no, a.father_guardian_name,
          a.parent_contact_no, a.emergency_contact_no, a.school_college, a.grade,
          a.address, a.date_of_birth, a.gender,
          coalesce(a.join_date, current_date), 'active', 'Cricket')
  returning members.id into v_member;

  -- A special plan's LENGTH is never stored. The app computes it in the
  -- browser (script.js:360) and sends only the resulting amount, so the
  -- only way back to the month count is to invert the price ladder:
  -- 10000/month, 5% off from 3 months, 10% off from 6. That is not a
  -- guess — it is the same inversion GenAlpha's own
  -- student_paid_through_date() performed, and it is why that function
  -- had a 36-iteration loop in it.
  --
  -- If no length reproduces the amount, v_special_months stays 1. That
  -- under-credits rather than over-credits, which is the direction a
  -- mistake should fall: a family chased early is a phone call, a family
  -- never chased is unpaid coaching.
  if lower(coalesce(a.fee_plan,'')) = 'special' and coalesce(a.coaching_fee,0) > 0 then
    select m into v_special_months
      from generate_series(1, 36) m
     where round(10000 * m * (case when m >= 6 then 0.90
                                   when m >= 3 then 0.95
                                   else 1 end))::numeric = round(a.coaching_fee)
     order by m limit 1;
    v_special_months := coalesce(v_special_months, 1);
  end if;

  -- 'special' carries its own length; months_covered is where the app
  -- puts it. Anything unrecognised is one month, which is the safe
  -- direction: it under-credits coverage rather than over-crediting it,
  -- and a family chased a month early is a phone call, not a refund.
  v_months := case lower(coalesce(a.fee_plan, ''))
                when 'quarterly'  then 3
                when 'halfyearly' then 6
                when 'special'    then v_special_months
                else 1 end;

  insert into genalpha.student_details (
    member_id, legacy_uuid, reg_no, time_slot, jersey_size, jersey_pairs,
    payment_method, payment_upi_id, payment_reference, fee_plan, coaching_fee,
    admission_fee, jersey_amount, total_fee_amount, admission_id, filled_by,
    fees_paid, amount_paid)
  values (v_member, gen_random_uuid(), a.reg_no, a.time_slot, a.jersey_size,
          a.jersey_pairs, a.payment_method, a.payment_upi_id, a.payment_reference,
          a.fee_plan, a.coaching_fee, a.admission_fee, a.jersey_amount,
          a.total_fee_amount, a.id, a.filled_by, a.fees_paid, a.amount_paid);

  -- The enrolment is not optional. renewal_on lives here and
  -- reminder_queue() reads it; a child approved without one is a child
  -- nobody ever chases for a fee.
  insert into public.enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                                  plan_months, joined_on, renewal_on, status)
  values ('genalpha', v_member, v_centre, v_batch, 'cricket',
          v_months,
          coalesce(a.join_date, current_date),
          coalesce(a.join_date, current_date) + make_interval(months => v_months),
          'active');

  -- The fee becomes a RULE, not a number on the child. resolve_fee() is
  -- the only thing allowed to answer "what does this family owe".
  if coalesce(a.coaching_fee,0) > 0 then
    -- coaching_fee is the TOTAL for the plan period, not a monthly rate.
    -- Dividing is the whole point: 2026-08-11y had to hand-repair two
    -- families whose entire quarter was stored as their monthly fee,
    -- because reminder_queue() quotes monthly_amount. plan_amounts keeps
    -- the exact agreed total so the division cannot round it away.
    insert into public.fee_rules (tenant_id, label, member_id, monthly_amount,
                                  plan_amounts, admission_fee, active, effective_from)
    values ('genalpha', 'Student fee · ' || a.applicant_name, v_member,
            round(a.coaching_fee / v_months, 2),
            case when v_months > 1
                 then jsonb_build_object(v_months::text, a.coaching_fee)
                 else jsonb_build_object('1', a.coaching_fee, '3', round(a.coaching_fee*3*0.95, 2),
                                         '6', round(a.coaching_fee*6*0.90, 2)) end,
            coalesce(a.admission_fee,0), true,
            coalesce(a.join_date, current_date));
  end if;

  update genalpha.admissions
     set review_status='approved', reviewed_at=now(),
         reviewed_by=coalesce(nullif(p_reviewed_by,''),'Manager'),
         review_notes=p_review_notes, approved_member_id=v_member
   where id = a.id;

  update public.applications
     set status='approved', reviewed_at=now(),
         reviewed_by=coalesce(nullif(p_reviewed_by,''),'Manager'),
         member_id=v_member
   where id = a.application_id;

  return query select v_member, a.reg_no;
end $function$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v_app uuid; v_member bigint; v_reg bigint; v_rule fee_rules; e enrollments;
  v_before int;
begin
  select count(*) into v_before from members where tenant_id='genalpha';

  -- Build a halfyearly admission and approve it. That is the case the old
  -- function got most wrong, and no live row exercises it.
  insert into genalpha.admissions
    (id, applicant_name, parent_contact_no, join_date, fee_plan, coaching_fee,
     admission_fee, jersey_amount, total_fee_amount, review_status, reg_no, fees_paid,
     consent_accepted, terms_accepted)
  values (gen_random_uuid(), 'ZZ Migration Probe', '9000000000', current_date,
          'halfyearly', 18900, 500, 0, 19400, 'pending',
          (select next_reg_no from genalpha.registration_counters where counter_name='admissions'),
          false, true, true)
  returning id into v_app;

  select member_id, reg_no into v_member, v_reg
    from genalpha.approve_admission(v_app, 'migration-probe', 'automated check');

  select * into e from enrollments where member_id = v_member and tenant_id='genalpha';
  if e.plan_months <> 6 then
    raise exception 'halfyearly produced a %-month enrolment', e.plan_months;
  end if;
  if e.renewal_on <> (current_date + interval '6 months')::date then
    raise exception 'renewal_on is %, expected six months out', e.renewal_on;
  end if;

  select * into v_rule from fee_rules where member_id = v_member and tenant_id='genalpha';
  if v_rule.monthly_amount <> 3150 then
    raise exception 'monthly rate is %, expected 3150 (18900/6)', v_rule.monthly_amount;
  end if;
  if (v_rule.plan_amounts->>'6')::numeric <> 18900 then
    raise exception 'the six-month total was not preserved: %', v_rule.plan_amounts;
  end if;

  -- and the number the platform would actually quote
  if (resolve_fee('genalpha', v_member, null, null, null, 6, null)->>'amount')::numeric <> 18900 then
    raise exception 'resolve_fee quotes % for six months, not 18900',
      (resolve_fee('genalpha', v_member, null, null, null, 6, null)->>'amount');
  end if;
  if (resolve_fee('genalpha', v_member, null, null, null, 1, null)->>'amount')::numeric <> 3150 then
    raise exception 'resolve_fee quotes % for one month, not 3150',
      (resolve_fee('genalpha', v_member, null, null, null, 1, null)->>'amount');
  end if;

  -- Clean the probe out entirely. A migration must not leave a fake child
  -- in a roster of real ones.
  delete from fee_rules   where member_id = v_member;
  delete from enrollments where member_id = v_member;
  delete from genalpha.student_details where member_id = v_member;
  delete from public.applications where member_id = v_member;
  delete from genalpha.admissions where id = v_app;
  delete from members where id = v_member;

  if (select count(*) from members where tenant_id='genalpha') <> v_before then
    raise exception 'the probe left a member behind';
  end if;

  -- The special-plan inversion, checked without writing anything: 28500
  -- is exactly 10000*3*0.95, so it must resolve to three months.
  if (select m from generate_series(1,36) m
       where round(10000*m*(case when m>=6 then 0.90 when m>=3 then 0.95 else 1 end))::numeric = 28500
       order by m limit 1) <> 3 then
    raise exception 'the special-plan ladder does not invert 28500 to 3 months';
  end if;

  raise notice 'approve_admission: halfyearly now gives a 6-month enrolment at 3150/month, total 18900 preserved';
end $$;
