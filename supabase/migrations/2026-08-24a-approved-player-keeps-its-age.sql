-- ============================================================
-- 2026-08-24a · An approved player keeps the age their form gave
-- scope: shared
--
-- approve_admission never copied the admission's age into
-- genalpha.student_details. It got away with it because the students view
-- reads COALESCE(d.age, year from age(m.dob)) and every admission carried a
-- date of birth, so an age was always derivable.
--
-- 2026-08-19g made a date of birth optional — a form may give one OR an age —
-- and the coalesce then had nothing to fall back on. KARTHIK - WUYYURU came
-- through with age 11 on his admission and NULL on the roster.
--
-- That is not one blank field. StudentDto parsed age as a non-null Int, so
-- Moshi threw "expected int but was null at $[0].age" and the mobile app
-- loaded no players at all. The app was hardened separately (v1.0.75 parses
-- every nullable column as nullable); this fixes the reason the null existed.
--
-- Both sources are used, admission age first, because an admission may now
-- legitimately carry either one.
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

  -- age is copied because nothing else will. genalpha.students reads
  -- COALESCE(d.age, year from age(m.dob)), and this insert used to set
  -- neither — every player approved here had a date of birth, so the view
  -- quietly derived one and the gap never showed. The moment an admission
  -- could carry an age WITHOUT a date of birth (2026-08-19g), the coalesce
  -- had nothing to fall back on: KARTHIK - WUYYURU arrived with age 11 on
  -- the admission and null on the roster, and a null age is not one bad
  -- field — Moshi refused the whole payload and the mobile roster showed
  -- nothing at all.
  insert into genalpha.student_details (
    member_id, legacy_uuid, reg_no, age, time_slot, jersey_size, jersey_pairs,
    payment_method, payment_upi_id, payment_reference, fee_plan, coaching_fee,
    admission_fee, jersey_amount, total_fee_amount, admission_id, filled_by,
    fees_paid, amount_paid)
  values (v_member, gen_random_uuid(), a.reg_no,
          coalesce(a.age, extract(year from age(coalesce(a.join_date, current_date),
                                                a.date_of_birth))::integer),
          a.time_slot, a.jersey_size,
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
          -- renewal_on is the date the NEXT fee falls due, and at approval no
          -- fee has been paid, so it is the join date itself. It used to be
          -- join_date + v_months, which handed every new player a free plan
          -- period before a rupee arrived: record_fee_payment then computes
          -- greatest(renewal_on, paid_on), so the joining payment bought a
          -- SECOND period and the next fee landed two months out. Four players
          -- were repaired below.
          coalesce(a.join_date, current_date),
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
end $function$
;


-- ------------------------------------------------------------
-- Every player already approved without an age. Guarded to rows that have
-- one available on the admission, so it cannot invent a number.
-- ------------------------------------------------------------
update genalpha.student_details d
   set age = coalesce(a.age, extract(year from age(coalesce(a.join_date, current_date),
                                                   a.date_of_birth))::integer)
  from genalpha.admissions a
 where a.id = d.admission_id
   and d.age is null
   and coalesce(a.age, extract(year from age(coalesce(a.join_date, current_date),
                                             a.date_of_birth))::integer) is not null;

do $$
declare v_null int; v_karthik int;
begin
  select count(*) into v_null
    from genalpha.student_details d
    join genalpha.admissions a on a.id = d.admission_id
   where d.age is null;
  if v_null > 0 then
    raise exception '% approved players still have no age', v_null;
  end if;

  select age into v_karthik from genalpha.students where name = 'KARTHIK - WUYYURU';
  if v_karthik is distinct from 11 then
    raise exception 'KARTHIK reads age %, expected 11', coalesce(v_karthik::text, 'null');
  end if;

  -- The roster is what broke. Nothing in it may carry a null age.
  select count(*) into v_null from genalpha.students where age is null;
  if v_null > 0 then
    raise exception '% players on the roster still have a null age', v_null;
  end if;

  raise notice 'every approved player carries the age their form gave';
end $$;
