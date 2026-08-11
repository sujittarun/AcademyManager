-- ============================================================
-- 2026-08-12d · approve_admission gets three things wrong
-- scope: shared
--
-- Nothing has gone through this path yet — 0 pending admissions, and all
-- 81 members came from the data migration. It fires on the first
-- approval, which is also the first thing the new mobile app will do.
--
--   reg_no / added_by   never written to public.members. The number went
--                       only to genalpha.student_details, but
--                       genalpha.students, reminder_events and
--                       reminder_tracker all read members.reg_no — so
--                       every approved child would show a blank
--                       registration number in the morning tracker.
--
--   plan_months         written with the true special-plan length.
--                       enrollments_plan_months_check allows only
--                       1/3/6/12, so a 2, 4 or 5-month special aborted
--                       the entire RPC: no member, no enrolment, no fee
--                       rule, admission still pending, raw Postgres error
--                       in a toast. A regression — 2026-08-10p always
--                       wrote 1 and always passed.
--
--   plan_amounts        applied the 5%/10% multi-month ladder to ANY
--                       rate. Those percentages are the academy's price
--                       list for the standard 3500 (giving 9975 and
--                       18900); applied to 3000 they invent an 8550
--                       quarter that nobody agreed, and that undercuts
--                       the 9000 an existing student on the same rate
--                       pays.
-- ============================================================

CREATE OR REPLACE FUNCTION genalpha.approve_admission(p_admission_id uuid, p_reviewed_by text DEFAULT 'Manager'::text, p_review_notes text DEFAULT ''::text)
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

  -- reg_no and added_by were missing here. The number went only to
  -- genalpha.student_details, but genalpha.students, reminder_events and
  -- reminder_tracker all read it from members.reg_no — so every child
  -- approved through this queue showed a blank registration number in the
  -- morning tracker. genalpha.students_write gets this right; this
  -- function was the outlier.
  insert into public.members (tenant_id, name, phone, parent_name, parent_phone, alt_phone,
                              school, grade, address, dob, gender, joined, status, program,
                              reg_no, added_by)
  values ('genalpha', a.applicant_name, a.parent_contact_no, a.father_guardian_name,
          a.parent_contact_no, a.emergency_contact_no, a.school_college, a.grade,
          a.address, a.date_of_birth, a.gender,
          coalesce(a.join_date, current_date), 'active', 'Cricket',
          a.reg_no, coalesce(nullif(p_reviewed_by, ''), 'Manager'))
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
          -- enrollments_plan_months_check only allows 1/3/6/12. A 2, 4 or
          -- 5-month special aborted the whole approval: no member, no
          -- enrolment, no fee rule, the admission left pending and a raw
          -- Postgres error in a toast. The true length still drives
          -- renewal_on and plan_amounts below; only this column snaps.
          case when v_months in (1,3,6,12) then v_months else 1 end,
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
            -- The 5%/10% ladder is the academy's price list for the
            -- STANDARD 3500 rate — 9975 and 18900 are its published
            -- quarterly and half-yearly prices. Applying those percentages
            -- to any other rate invents a discount nobody agreed: a
            -- 3000-a-month student would be quoted 8550 for a quarter
            -- while an existing one on the same rate is quoted 9000.
            -- 2026-08-11y says this in writing and this function did the
            -- opposite.
            case when v_months > 1
                 then jsonb_build_object(v_months::text, a.coaching_fee)
                 when a.coaching_fee = 3500
                 then jsonb_build_object('1', 3500, '3', 9975, '6', 18900)
                 else jsonb_build_object('1', a.coaching_fee) end,
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
-- Checks — a 2-month special, which is the case that aborted
-- ------------------------------------------------------------
do $$
declare
  v_app uuid; v_member bigint; v_reg bigint; e enrollments; r fee_rules;
  m0 int; n int;
begin
  select count(*) into m0 from members where tenant_id='genalpha';

  -- 20000 is exactly 10000 * 2, the two-month special price. The old
  -- function inverted that to v_months = 2, wrote it into plan_months and
  -- the whole approval died on the check constraint.
  insert into genalpha.admissions
    (id, applicant_name, parent_contact_no, join_date, fee_plan, coaching_fee,
     admission_fee, jersey_amount, total_fee_amount, review_status, reg_no,
     fees_paid, consent_accepted, terms_accepted)
  values (gen_random_uuid(), 'ZZ Special Probe', '9000000005', current_date,
          'special', 20000, 0, 0, 20000, 'pending',
          (select next_reg_no from genalpha.registration_counters where counter_name='admissions'),
          false, true, true)
  returning id into v_app;

  select member_id, reg_no into v_member, v_reg
    from genalpha.approve_admission(v_app, 'zz-probe', 'automated check');
  if v_member is null then raise exception 'the two-month special still fails to approve'; end if;

  -- reg_no must be ON THE MEMBER, which is where every view reads it
  if (select reg_no from members where id = v_member) is null then
    raise exception 'members.reg_no is still blank after approval';
  end if;
  if (select added_by from members where id = v_member) is distinct from 'zz-probe' then
    raise exception 'members.added_by was not recorded';
  end if;
  -- and therefore visible in the tracker the manager reads
  if not exists (select 1 from genalpha.students s where s.id =
                   (select legacy_uuid from genalpha.student_details where member_id = v_member)
                   and s.reg_no is not null) then
    raise exception 'the approved child still shows a blank reg no in genalpha.students';
  end if;

  select * into e from enrollments where member_id = v_member and tenant_id='genalpha';
  if e.plan_months not in (1,3,6,12) then
    raise exception 'plan_months is %, which the check constraint forbids', e.plan_months;
  end if;
  -- the TRUE length still drives coverage, even though plan_months snapped
  if e.renewal_on <> (current_date + interval '2 months')::date then
    raise exception 'renewal_on is %, expected two months out', e.renewal_on;
  end if;

  select * into r from fee_rules where member_id = v_member and tenant_id='genalpha';
  if (r.plan_amounts->>'2')::numeric <> 20000 then
    raise exception 'the two-month price was not preserved: %', r.plan_amounts;
  end if;
  if r.plan_amounts ? '3' or r.plan_amounts ? '6' then
    raise exception 'a discount was invented for a non-standard rate: %', r.plan_amounts;
  end if;

  -- clean up entirely
  delete from fee_rules   where member_id = v_member;
  delete from enrollments where member_id = v_member;
  delete from genalpha.student_details where member_id = v_member;
  delete from public.applications where member_id = v_member;
  delete from genalpha.admissions where id = v_app;
  delete from member_timeline where member_id = v_member;
  delete from members where id = v_member;
  if (select count(*) from members where tenant_id='genalpha') <> m0 then
    raise exception 'the probe left a member behind';
  end if;

  raise notice 'a 2-month special approves; reg_no and added_by land on the member; no invented discount';
end $$;
