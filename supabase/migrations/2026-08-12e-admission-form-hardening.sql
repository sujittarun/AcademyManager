-- ============================================================
-- 2026-08-12e · The public admission form: a cap, and the consent it drops
-- scope: shared
--
-- The fee question here is settled — custom pricing is deliberate, live
-- rules run Rs 1,500 to Rs 10,000, and the manager now sees the amount on
-- the approve card before it becomes a fee rule. Two other things on the
-- same function are not settled.
--
--   NO RATE LIMIT. Every successful call consumes a registration number,
--   and this function is anon-executable with a key published in the app.
--   Nothing stopped a script burning the sequence. The numbers go on
--   receipts and ID cards, so gaps are not cosmetic.
--   public.submit_application exists as precisely this hardening for the
--   platform's own form and is bypassed here.
--
--   CONSENT DROPPED ON THE FLOOR. The platform row was written with ten
--   columns and left consent_accepted, terms_accepted,
--   consent_accepted_at, address, city, age, emergency_contact_no,
--   join_date, comments and filled_by null — the columns 2026-08-10q
--   added citing this exact form, whose header calls the missing consent
--   "the one that should embarrass us: the platform takes registrations
--   for MINORS across six academies". The form captures it. The genalpha
--   row stores it. The platform row threw it away.
-- ============================================================

CREATE OR REPLACE FUNCTION genalpha.submit_admission_form(p_applicant_name text, p_nationality text, p_date_of_birth date, p_age integer, p_gender text, p_father_guardian_name text, p_alternate_contact_no text, p_parent_contact_no text, p_city text, p_address text, p_school_college text, p_grade text, p_parent_aadhaar_no text, p_time_slot text, p_join_date date, p_fees_paid boolean, p_amount_paid numeric, p_jersey_size text, p_jersey_pairs integer, p_batsman_style text, p_bowling_styles text[], p_ready_to_start boolean, p_consent_accepted boolean, p_terms_accepted boolean, p_payment_method text DEFAULT 'UPI'::text, p_payment_upi_id text DEFAULT ''::text, p_payment_reference text DEFAULT ''::text, p_comments text DEFAULT ''::text, p_filled_by text DEFAULT 'Parent / Guardian'::text, p_fee_plan text DEFAULT 'monthly'::text, p_coaching_fee numeric DEFAULT 0, p_admission_fee numeric DEFAULT 0, p_jersey_amount numeric DEFAULT 0, p_total_fee_amount numeric DEFAULT 0)
 RETURNS TABLE(id uuid, reg_no bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare v_reg bigint; v_app bigint; v_id uuid;
begin
  if not coalesce(p_consent_accepted,false) or not coalesce(p_terms_accepted,false) then
    raise exception 'Please accept the required consent and terms.';
  end if;
  -- This function is reachable without a session, so it validates rather
  -- than trusts. The original did neither.
  if coalesce(length(trim(p_applicant_name)),0) < 2 then
    raise exception 'Please enter the applicant''s name.';
  end if;
  if coalesce(length(regexp_replace(coalesce(p_parent_contact_no,''), '\D', '', 'g')),0) < 10 then
    raise exception 'Please enter a valid contact number.';
  end if;

  -- A registration number is consumed on every successful call, and this
  -- function is anon-executable with a key published in the app. Nothing
  -- stopped a script burning the sequence — the numbers appear on
  -- receipts and ID cards, so gaps are not cosmetic.
  --
  -- public.submit_application exists as exactly this hardening for the
  -- platform's own form (schema.sql:717) and is bypassed here, so the
  -- same shape is applied: a per-phone daily cap, checked before the
  -- counter moves.
  if (select count(*) from genalpha.admissions a
       where regexp_replace(coalesce(a.parent_contact_no,''), '\D', '', 'g')
             = regexp_replace(coalesce(p_parent_contact_no,''), '\D', '', 'g')
         and a.created_at > now() - interval '24 hours') >= 5 then
    raise exception 'Too many admission forms from this number today. Please contact the academy.'
      using errcode = 'too_many_connections';
  end if;

  update genalpha.registration_counters
     set next_reg_no = next_reg_no + 1
   where counter_name = 'admissions'
  returning next_reg_no - 1 into v_reg;

  -- the platform-level row, so GenAlpha counts like every other tenant
  -- 2026-08-10q added consent_accepted, terms_accepted, address, city,
  -- age, emergency_contact_no, join_date, comments and filled_by to this
  -- table citing THIS form, and called the missing consent columns the
  -- thing that should embarrass us: the platform takes registrations for
  -- minors across six academies. The form captures consent, the genalpha
  -- row stores it, and the platform row was still left null.
  insert into public.applications (tenant_id, name, phone, parent_name, parent_phone,
                                   dob, gender, school, sport, status,
                                   address, city, age, emergency_contact_no,
                                   join_date, comments, filled_by, source_channel,
                                   consent_accepted, terms_accepted, consent_accepted_at)
  values ('genalpha', p_applicant_name, p_parent_contact_no, p_father_guardian_name,
          p_parent_contact_no, p_date_of_birth, p_gender, p_school_college, 'cricket', 'pending',
          p_address, p_city, p_age, p_alternate_contact_no,
          p_join_date, p_comments, p_filled_by, 'web_form',
          p_consent_accepted, p_terms_accepted, now())
  returning applications.id into v_app;

  insert into genalpha.admissions (
    application_id, reg_no, applicant_name, nationality, date_of_birth, age, gender,
    father_guardian_name, parent_contact_no, emergency_contact_no, city, address,
    school_college, grade, parent_aadhaar_no, time_slot, join_date, fees_paid,
    amount_paid, fee_plan, coaching_fee, admission_fee, jersey_amount, total_fee_amount,
    jersey_size, jersey_pairs, payment_method, payment_upi_id, payment_reference,
    filled_by, comments, batsman_style, bowling_styles, ready_to_start,
    consent_accepted, terms_accepted)
  values (
    v_app, v_reg, p_applicant_name, p_nationality, p_date_of_birth, p_age, p_gender,
    p_father_guardian_name, p_parent_contact_no, p_alternate_contact_no, p_city, p_address,
    p_school_college, p_grade, p_parent_aadhaar_no, p_time_slot, p_join_date,
    coalesce(p_fees_paid,false), coalesce(p_amount_paid,0), p_fee_plan,
    coalesce(p_coaching_fee,0), coalesce(p_admission_fee,0), coalesce(p_jersey_amount,0),
    coalesce(p_total_fee_amount,0), p_jersey_size, coalesce(p_jersey_pairs,0),
    p_payment_method, p_payment_upi_id, p_payment_reference, p_filled_by, p_comments,
    p_batsman_style, p_bowling_styles, p_ready_to_start, true, true)
  returning admissions.id into v_id;

  return query select v_id, v_reg;
end $function$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
-- The 24 leading parameters have no defaults, so every probe passes them
-- positionally. That is also how the app calls it (script.js:7143).
do $$
declare v_id uuid; v_reg bigint; a0 int; c0 bigint; n int; blocked boolean := false; v_app bigint;
begin
  select count(*) into a0 from genalpha.admissions;
  select next_reg_no into c0 from genalpha.registration_counters where counter_name='admissions';

  select id, reg_no into v_id, v_reg from genalpha.submit_admission_form(
      'ZZ Consent Probe', 'Indian', date '2016-05-05', 9, 'male', 'ZZ Parent', '9000000007',
      '9000000006', 'Hyderabad', 'ZZ Address', 'ZZ School', '5', '', '6AM',
      current_date, false, 0, 'M', 0, 'right', array['right']::text[], true, true, true
      , p_fee_plan => 'monthly', p_coaching_fee => 3500, p_admission_fee => 500,
      p_total_fee_amount => 4000, p_filled_by => 'probe', p_comments => 'probe');
  if v_reg is null then raise exception 'the submission returned no registration number'; end if;

  -- THE POINT: consent must reach the PLATFORM row, not only genalpha's.
  select a.id into v_app from public.applications a
   where a.tenant_id='genalpha' and a.name='ZZ Consent Probe';
  if v_app is null then raise exception 'no platform application row was written'; end if;
  if not exists (select 1 from public.applications
                  where id = v_app and consent_accepted and terms_accepted
                    and consent_accepted_at is not null
                    and address = 'ZZ Address' and city = 'Hyderabad'
                    and emergency_contact_no = '9000000007'
                    and source_channel = 'web_form') then
    raise exception 'the platform application row still drops consent and the rest';
  end if;

  -- THE CAP: a sixth form from one number in a day is refused, and
  -- refused BEFORE the counter moves.
  for n in 1..4 loop
    perform * from genalpha.submit_admission_form(
      'ZZ Flood ' || n, 'Indian', date '2016-05-05', 9, 'male', 'ZZ Parent', '9000000007',
      '9000000006', 'Hyderabad', 'ZZ Address', 'ZZ School', '5', '', '6AM',
      current_date, false, 0, 'M', 0, 'right', array['right']::text[], true, true, true
      , p_fee_plan => 'monthly');
  end loop;
  begin
    perform * from genalpha.submit_admission_form(
      'ZZ Flood 6', 'Indian', date '2016-05-05', 9, 'male', 'ZZ Parent', '9000000007',
      '9000000006', 'Hyderabad', 'ZZ Address', 'ZZ School', '5', '', '6AM',
      current_date, false, 0, 'M', 0, 'right', array['right']::text[], true, true, true
      , p_fee_plan => 'monthly');
  exception when too_many_connections then blocked := true;
  end;
  if not blocked then raise exception 'a sixth form from one number in a day was accepted'; end if;

  if (select next_reg_no from genalpha.registration_counters where counter_name='admissions')
     <> c0 + 5 then
    raise exception 'the counter moved % times, expected 5',
      (select next_reg_no from genalpha.registration_counters where counter_name='admissions') - c0;
  end if;

  -- a different number is unaffected
  perform * from genalpha.submit_admission_form(
      'ZZ Other Number', 'Indian', date '2016-05-05', 9, 'male', 'ZZ Parent', '9000000007',
      '9000000008', 'Hyderabad', 'ZZ Address', 'ZZ School', '5', '', '6AM',
      current_date, false, 0, 'M', 0, 'right', array['right']::text[], true, true, true
      , p_fee_plan => 'monthly');

  delete from public.applications where tenant_id='genalpha' and name like 'ZZ %';
  delete from genalpha.admissions where applicant_name like 'ZZ %';
  update genalpha.registration_counters set next_reg_no = c0 where counter_name='admissions';

  if (select count(*) from genalpha.admissions) <> a0 then
    raise exception 'the probe left admissions behind';
  end if;

  raise notice 'consent reaches the platform row; a sixth form in a day is refused and burns no number';
end $$;
