-- ============================================================
-- 2026-08-11t · The five RPCs admission-intake calls
-- scope: shared
--
-- The edge function talks to PostgREST by raw URL and calls five RPCs.
-- None existed on the platform. Three port across with nothing changed
-- but the schema, because everything they touch is GenAlpha's own
-- (admissions, registration_counters, the intake tables).
--
-- Two do NOT port, and porting them would have been the mistake:
--
--   student_paid_through_date  reconstructs a paid-through date from 60
--     lines of fee archaeology — jersey subtraction, admission-fee
--     subtraction, a 36-iteration loop over special-plan prices, then
--     greatest() across the renewals array and the payments table. The
--     platform stores that date. It is enrollments.renewal_on, and it was
--     DERIVED FROM THIS FUNCTION during the merge, so the two agree by
--     construction. Keeping the arithmetic would create a second opinion
--     about when a family's fees run out, which is the exact thing the
--     house rule exists to stop.
--
--   finalize_renewal_intake  is a second money engine. It writes the
--     payment, rolls the renewal forward, and writes the timeline — all
--     three of which record_fee_payment() owns. It also hardcodes prices.
--     Its VALIDATION is genuinely GenAlpha's and is kept verbatim: the
--     duplicate-reference check, the screenshot-status check, the
--     already-paid-this-cycle check. Only the write delegates.
--
-- backfill_intake_payment_proof_path is rewritten for the same reason at
-- one remove: it edited student_payments and student_timeline, which are
-- read-only views here, so it now edits payments and member_timeline.
--
-- WHAT THIS DOES NOT FIX. resolve_fee('genalpha', months => 3) returns
-- 10500 where GenAlpha charges 9975, and 21000 for six months where
-- GenAlpha charges 18900. The platform's fee chain has no multi-month
-- discount. finalize_renewal_intake does not hit that, because the parent
-- states the amount they paid and the function validates it — but
-- reminder_queue() will quote the undiscounted number to a quarterly
-- family. That is a real gap and needs its own change; it is called out
-- here rather than papered over.
-- ============================================================

-- ---- normalize_admission_intake_slot: ported unchanged apart from the schema ----
create or replace function genalpha.normalize_admission_intake_slot(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case regexp_replace(lower(coalesce(p_value, '')), '[^0-9a-z]+', '', 'g')
    when '6am' then '6AM'
    when '600am730am' then '6AM'
    when '730am' then '7:30AM'
    when '730am900am' then '7:30AM'
    when '4pm' then '4PM'
    when '400pm530pm' then '4PM'
    when '530pm' then '5:30PM'
    when '530pm700pm' then '5:30PM'
    when '7pm' then '7PM'
    when '700pm830pm' then '7PM'
    else ''
  end;
$function$
;

-- ---- get_or_create_admission_intake_session: ported unchanged apart from the schema ----
create or replace function genalpha.get_or_create_admission_intake_session(p_channel text, p_source_chat_id text, p_source_sender_id text, p_source_sender_name text DEFAULT ''::text, p_message_timestamp timestamp with time zone DEFAULT now())
 RETURNS SETOF genalpha.admission_intake_sessions
 LANGUAGE plpgsql
 SECURITY DEFINER
 set search_path = genalpha, public
AS $function$
declare
  v_session genalpha.admission_intake_sessions%rowtype;
  v_sender_key text;
  v_lock_key text;
begin
  if p_channel not in ('whatsapp', 'whatsapp_group', 'web') then
    raise exception 'Unsupported intake channel.';
  end if;
  if btrim(coalesce(p_source_chat_id, '')) = '' then
    raise exception 'Intake chat ID is required.';
  end if;

  v_sender_key := case when p_channel = 'whatsapp_group'
    then '' else coalesce(p_source_sender_id, '') end;
  v_lock_key := concat('admission-intake:', p_channel, ':', p_source_chat_id, ':', v_sender_key);
  perform pg_advisory_xact_lock(hashtextextended(v_lock_key, 0));

  select * into v_session
  from genalpha.admission_intake_sessions s
  where s.source_chat_id = p_source_chat_id
    and (p_channel = 'whatsapp_group' or s.source_sender_id = coalesce(p_source_sender_id, ''))
    and s.status = 'collecting'
    and s.last_message_at >= now() - interval '30 minutes'
  order by s.last_message_at desc, s.created_at desc
  limit 1
  for update;

  if not found then
    insert into genalpha.admission_intake_sessions (
      channel, source_chat_id, source_sender_id, source_sender_name,
      status, opened_at, last_message_at, expires_at, created_by
    ) values (
      p_channel, p_source_chat_id, coalesce(p_source_sender_id, ''),
      coalesce(p_source_sender_name, ''), 'collecting',
      coalesce(p_message_timestamp, now()), coalesce(p_message_timestamp, now()),
      now() + interval '24 hours',
      case when p_channel = 'web' then 'Manager web intake' else 'WhatsApp intake' end
    ) returning * into v_session;
  end if;

  return next v_session;
end;
$function$
;

-- ---- finalize_admission_intake: ported unchanged apart from the schema ----
create or replace function genalpha.finalize_admission_intake(p_session_id uuid, p_confirmation_message_id text DEFAULT ''::text, p_confirmed_by text DEFAULT 'WhatsApp staff'::text)
 RETURNS TABLE(admission_id uuid, reg_no bigint, payment_claim_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 set search_path = genalpha, public
AS $function$
declare
  v_session genalpha.admission_intake_sessions%rowtype;
  v_draft jsonb;
  v_payment jsonb;
  v_name text;
  v_nationality text;
  v_gender text;
  v_guardian text;
  v_phone text;
  v_alt_phone text;
  v_school text;
  v_address text;
  v_slot text;
  v_dob date;
  v_join_date date;
  v_age integer;
  v_plan text;
  v_months integer;
  v_jersey_pairs integer;
  v_coaching numeric(10, 2);
  v_admission_fee numeric(10, 2) := 500;
  v_jersey numeric(10, 2);
  v_total numeric(10, 2);
  v_claim_amount numeric(10, 2);
  v_claimed_paid boolean;
  v_evidence_type text;
  v_payment_date date;
  v_payment_method text;
  v_payment_reference text;
  v_bowling_styles text[] := '{}';
  v_ready_to_start boolean;
  v_consent_accepted boolean;
  v_terms_accepted boolean;
  v_reg_no bigint;
  v_admission_id uuid;
  v_claim_id uuid;
begin
  select * into v_session
  from genalpha.admission_intake_sessions
  where id = p_session_id
  for update;

  if not found then
    raise exception 'Admission intake session not found.';
  end if;

  if v_session.admission_id is not null then
    return query
    select v_session.admission_id, a.reg_no, c.id
    from genalpha.admissions a
    left join genalpha.admission_payment_claims c on c.session_id = v_session.id
    where a.id = v_session.admission_id;
    return;
  end if;

  if v_session.status not in ('waiting_for_confirmation', 'confirmed') then
    raise exception 'Admission draft must be waiting for confirmation.';
  end if;

  if coalesce(array_length(v_session.missing_fields, 1), 0) > 0 then
    raise exception 'Admission still has missing required fields: %', array_to_string(v_session.missing_fields, ', ');
  end if;

  if jsonb_array_length(coalesce(v_session.conflicts, '[]'::jsonb)) > 0 then
    raise exception 'Admission still has unresolved conflicts.';
  end if;

  v_draft := v_session.draft;
  v_payment := coalesce(v_draft->'payment', '{}'::jsonb);
  v_name := btrim(coalesce(v_draft->>'applicant_name', ''));
  v_nationality := btrim(coalesce(v_draft->>'nationality', ''));
  v_gender := btrim(coalesce(v_draft->>'gender', ''));
  v_guardian := btrim(coalesce(v_draft->>'father_guardian_name', ''));
  v_phone := right(regexp_replace(coalesce(v_draft->>'parent_contact_no', ''), '\D', '', 'g'), 10);
  v_alt_phone := right(regexp_replace(coalesce(v_draft->>'alternate_contact_no', ''), '\D', '', 'g'), 10);
  v_school := btrim(coalesce(v_draft->>'school_college', ''));
  v_address := btrim(coalesce(v_draft->>'address', ''));
  v_slot := genalpha.normalize_admission_intake_slot(v_draft->>'time_slot');
  v_dob := nullif(v_draft->>'date_of_birth', '')::date;
  v_join_date := nullif(v_draft->>'join_date', '')::date;
  v_age := case
    when v_dob is not null and v_join_date is not null then
      extract(year from age(v_join_date, v_dob))::integer
    else nullif(v_draft->>'age', '')::integer
  end;
  v_plan := lower(btrim(coalesce(v_draft->>'fee_plan', '')));
  v_ready_to_start := coalesce((v_draft->>'ready_to_start')::boolean, false);
  v_consent_accepted := coalesce((v_draft->>'consent_accepted')::boolean, false);
  v_terms_accepted := coalesce((v_draft->>'terms_accepted')::boolean, false);

  if jsonb_typeof(v_draft->'bowling_styles') = 'array' then
    select coalesce(array_agg(value), '{}')
    into v_bowling_styles
    from jsonb_array_elements_text(v_draft->'bowling_styles');
  end if;

  if v_name = '' then raise exception 'Student name is required.'; end if;
  if v_nationality = '' then raise exception 'Nationality is required.'; end if;
  if v_dob is null then raise exception 'Date of birth is required.'; end if;
  if v_age not between 4 and 18 then raise exception 'Student age is outside the app admission range.'; end if;
  if v_gender = '' then raise exception 'Gender is required.'; end if;
  if v_guardian = '' then raise exception 'Father or guardian name is required.'; end if;
  if length(v_phone) <> 10 then raise exception 'A valid 10-digit parent contact is required.'; end if;
  if length(v_alt_phone) <> 10 then raise exception 'A valid 10-digit alternate contact is required.'; end if;
  if v_school = '' then raise exception 'School or college is required.'; end if;
  if v_address = '' then raise exception 'Home address is required.'; end if;
  if v_slot = '' then raise exception 'Batch timing is missing or invalid.'; end if;
  if v_join_date is null then raise exception 'Joining date is required.'; end if;
  if not v_consent_accepted or not v_terms_accepted then
    raise exception 'Signed parent consent and academy terms are required.';
  end if;

  v_claim_amount := greatest(coalesce(nullif(v_payment->>'amount', '')::numeric, 0), 0);
  v_claimed_paid := coalesce((v_payment->>'claimed_paid')::boolean, false)
    or v_claim_amount > 0
    or coalesce(v_payment->>'proof_path', '') <> '';
  v_evidence_type := lower(coalesce(v_payment->>'evidence_type', 'none'));
  v_payment_date := nullif(v_payment->>'payment_date', '')::date;
  v_payment_method := btrim(coalesce(v_payment->>'payment_method', ''));
  v_payment_reference := coalesce(nullif(v_payment->>'transaction_id', ''), v_payment->>'utr', '');

  if v_claimed_paid then
    if v_plan not in ('monthly', 'quarterly', 'halfyearly', 'special', 'custom') then
      raise exception 'A valid fee plan is required when payment is marked paid.';
    end if;
  elsif v_plan not in ('monthly', 'quarterly', 'halfyearly', 'special', 'custom') then
    v_plan := 'pending';
  end if;

  v_months := greatest(coalesce(nullif(v_draft->>'months_covered', '')::integer, 1), 1);
  v_jersey_pairs := greatest(coalesce(nullif(v_draft->>'jersey_pairs', '')::integer, 0), 0);
  v_coaching := case v_plan
    when 'monthly' then 3500
    when 'quarterly' then 9975
    when 'halfyearly' then 18900
    when 'special' then round(10000 * v_months * case when v_months >= 6 then 0.90 when v_months >= 3 then 0.95 else 1 end, 2)
    when 'custom' then greatest(coalesce(nullif(v_draft->>'custom_coaching_fee', '')::numeric, 0), 0)
    else 0
  end;
  if v_plan = 'custom' and v_coaching <= 0 then
    raise exception 'A positive custom coaching fee is required.';
  end if;
  v_admission_fee := case when v_plan in ('pending', 'special') then 0 else 500 end;
  v_jersey := case when v_plan = 'pending' then 0 else v_jersey_pairs * 750 end;
  v_total := v_coaching + v_admission_fee + v_jersey;

  if v_claimed_paid then
    if v_payment_date is null then raise exception 'Payment date is required for the marked-paid fee.'; end if;
    if v_claim_amount <= 0 then raise exception 'Payment amount is required for the marked-paid fee.'; end if;
    if coalesce(v_payment->>'proof_path', '') = ''
      and v_payment_reference = ''
      and v_evidence_type <> 'cash_statement'
      and v_payment_method !~* '\mcash\M' then
      raise exception 'Send a payment screenshot or confirm the cash amount before saving.';
    end if;
  end if;

  if v_payment_method = '' then
    v_payment_method := case when v_evidence_type = 'cash_statement' then 'Cash' else 'UPI' end;
  end if;

  insert into genalpha.registration_counters (counter_name, next_reg_no)
  values ('admissions', 1001)
  on conflict (counter_name) do nothing;

  update genalpha.registration_counters
  set next_reg_no = next_reg_no + 1
  where counter_name = 'admissions'
  returning next_reg_no - 1 into v_reg_no;

  insert into genalpha.admissions (
    reg_no, applicant_name, nationality, date_of_birth, age, gender,
    father_guardian_name, emergency_contact_no, parent_contact_no,
    city, address, school_college, grade, parent_aadhaar_no,
    time_slot, join_date, fees_paid, amount_paid, fee_plan,
    coaching_fee, admission_fee, jersey_amount, total_fee_amount,
    jersey_size, jersey_pairs, payment_method, payment_upi_id,
    payment_reference, comments, filled_by, batsman_style,
    bowling_styles, ready_to_start, consent_accepted, terms_accepted,
    review_status, intake_session_id, source_channel, source_confidence,
    payment_verification_status
  ) values (
    v_reg_no, v_name, v_nationality, v_dob, v_age, v_gender,
    v_guardian, v_alt_phone, v_phone,
    coalesce(v_draft->>'city', ''), v_address, v_school,
    coalesce(v_draft->>'grade', ''), coalesce(v_draft->>'parent_aadhaar_no', ''),
    v_slot, v_join_date, false, v_claim_amount, v_plan,
    v_coaching, v_admission_fee, v_jersey, v_total,
    coalesce(v_draft->>'jersey_size', ''), v_jersey_pairs,
    v_payment_method, coalesce(v_payment->>'upi_id', ''), v_payment_reference,
    coalesce(v_draft->>'comments', ''),
    coalesce(nullif(v_draft->>'filled_by', ''), 'Parent / Guardian'),
    coalesce(v_draft->>'batsman_style', ''), v_bowling_styles,
    v_ready_to_start, v_consent_accepted, v_terms_accepted,
    'pending', v_session.id, v_session.channel, v_session.overall_confidence,
    case when v_claimed_paid then 'pending_verification' else '' end
  ) returning id into v_admission_id;

  if v_claimed_paid then
    insert into genalpha.admission_payment_claims (
      session_id, admission_id, amount, payment_date, payment_time,
      payment_method, payment_reference, utr, payer_name, receiver_name,
      screenshot_status, verification_status, confidence,
      proof_bucket, proof_path, extracted_data
    ) values (
      v_session.id, v_admission_id, v_claim_amount, v_payment_date,
      nullif(v_payment->>'payment_time', '')::time,
      v_payment_method, coalesce(v_payment->>'transaction_id', ''),
      coalesce(v_payment->>'utr', ''), coalesce(v_payment->>'payer_name', ''),
      coalesce(v_payment->>'receiver_name', ''),
      case lower(coalesce(v_payment->>'screenshot_status', 'unknown'))
        when 'successful' then 'successful' when 'failed' then 'failed'
        when 'pending' then 'pending' when 'processing' then 'processing'
        else 'unknown' end,
      'pending', nullif(v_payment->>'confidence', '')::numeric,
      coalesce(v_payment->>'proof_bucket', ''), coalesce(v_payment->>'proof_path', ''),
      v_payment
    ) returning id into v_claim_id;
  end if;

  update genalpha.admission_intake_sessions
  set status = 'confirmed', admission_id = v_admission_id,
      confirmation_message_id = coalesce(p_confirmation_message_id, ''),
      confirmed_by = coalesce(nullif(p_confirmed_by, ''), 'WhatsApp staff'),
      confirmed_at = coalesce(confirmed_at, now()), error_code = '', error_message = ''
  where id = v_session.id;

  return query select v_admission_id, v_reg_no, v_claim_id;
end;
$function$
;

-- ---- student_paid_through_date: the platform already knows this ----
create or replace function genalpha.student_paid_through_date(p_student_id uuid)
returns date
language sql
stable
security definer
set search_path = genalpha, public
as $$
  select e.renewal_on
    from genalpha.student_details d
    join enrollments e on e.member_id = d.member_id and e.tenant_id = 'genalpha'
   where d.legacy_uuid = p_student_id
$$;

comment on function genalpha.student_paid_through_date(uuid) is
  'enrollments.renewal_on for a GenAlpha player. The pre-merge version recomputed this from fee arithmetic; renewal_on was seeded from that computation, so they agree — and now there is only one of them.';

-- ---- finalize_renewal_intake: GenAlpha validates, the platform pays ----
create or replace function genalpha.finalize_renewal_intake(
  p_session_id uuid,
  p_confirmation_message_id text default '',
  p_confirmed_by text default 'WhatsApp staff'
)
returns table (
  payment_id        bigint,
  student_id        uuid,
  student_name      text,
  reg_no            bigint,
  cycle_start_date  date,
  renewal_to_date   date
)
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare
  v_session       genalpha.admission_intake_sessions%rowtype;
  v_student       genalpha.students%rowtype;
  v_member        bigint;
  v_enrollment    bigint;
  v_draft         jsonb;
  v_payment       jsonb;
  v_plan          text;
  v_months        integer;
  v_amount        numeric(10,2);
  v_paid_on       date;
  v_cycle_start   date;
  v_to_date       date;
  v_reference     text;
  v_proof_path    text;
  v_is_joining    boolean;
  v_coaching      numeric(10,2);
  v_admission_fee numeric(10,2);
  v_jersey        numeric(10,2);
  v_result        jsonb;
  v_payment_id    bigint;
begin
  select * into v_session
    from genalpha.admission_intake_sessions
   where id = p_session_id
     for update;
  if not found then raise exception 'Intake session not found.'; end if;

  -- Already done: return what was recorded, do not record it twice.
  if v_session.renewal_payment_id is not null then
    return query
      select p.id, d.legacy_uuid, m.name, m.reg_no, p.period_from, p.period_to
        from payments p
        join genalpha.student_details d on d.member_id = p.member_id
        join members m on m.id = p.member_id
       where p.id = v_session.renewal_payment_id
         and p.tenant_id = 'genalpha';
    return;
  end if;

  -- ---- GenAlpha's own rules, unchanged ----
  if v_session.intake_type <> 'renewal' then
    raise exception 'This intake is not a renewal.';
  end if;
  if v_session.status not in ('waiting_for_confirmation', 'confirmed') then
    raise exception 'Renewal draft must be waiting for confirmation.';
  end if;
  if cardinality(coalesce(v_session.missing_fields, '{}'::text[])) > 0 then
    raise exception 'Renewal draft still has missing fields.';
  end if;
  if v_session.matched_student_id is null then
    raise exception 'A unique player match is required.';
  end if;

  select * into v_student from genalpha.students where id = v_session.matched_student_id;
  if not found then raise exception 'Matched player no longer exists.'; end if;

  -- students is a view, so the row lock goes on the member it is built
  -- from. Without this two confirmations of the same renewal race.
  select d.member_id into v_member
    from genalpha.student_details d where d.legacy_uuid = v_session.matched_student_id;
  perform 1 from members where id = v_member for update;

  select e.id into v_enrollment
    from enrollments e where e.tenant_id = 'genalpha' and e.member_id = v_member;
  if v_enrollment is null then
    raise exception 'This player has no enrollment to pay against.';
  end if;

  v_draft   := coalesce(v_session.draft, '{}'::jsonb);
  v_payment := coalesce(v_draft->'payment', '{}'::jsonb);
  v_plan    := lower(coalesce(nullif(v_draft->>'plan_type', ''), 'monthly'));
  if v_plan not in ('monthly', 'quarterly', 'halfyearly', 'special', 'custom') then
    raise exception 'Renewal plan is missing or invalid.';
  end if;
  v_months := case v_plan
    when 'monthly'    then 1
    when 'quarterly'  then 3
    when 'halfyearly' then 6
    else greatest(coalesce(nullif(v_draft->>'months_covered', '')::integer, 1), 1)
  end;
  v_amount     := greatest(coalesce(nullif(v_payment->>'amount', '')::numeric, 0), 0);
  v_paid_on    := nullif(v_payment->>'payment_date', '')::date;
  v_reference  := btrim(coalesce(nullif(v_payment->>'transaction_id', ''), v_payment->>'utr', ''));
  v_proof_path := btrim(coalesce(v_payment->>'proof_path', ''));

  if v_amount <= 0 then raise exception 'Renewal payment amount is required.'; end if;
  if v_paid_on is null then raise exception 'Renewal payment date is required.'; end if;
  if v_reference = '' and v_proof_path = '' then
    raise exception 'A payment reference or screenshot is required.';
  end if;
  if lower(coalesce(v_payment->>'screenshot_status', 'unknown')) in ('failed','pending','processing') then
    raise exception 'The payment screenshot does not show a completed payment.';
  end if;

  -- Duplicate-reference check, now against platform payments. Scoped to
  -- genalpha: a UTR is unique to a bank, not to this academy, and an
  -- unscoped check would let one tenant probe another's references.
  if v_reference <> '' and exists (
    select 1 from payments p
     where p.tenant_id = 'genalpha'
       and lower(btrim(coalesce(p.ref, ''))) = lower(v_reference)
  ) then
    raise exception 'This payment reference was already recorded.';
  end if;

  v_is_joining  := not coalesce(v_student.fees_paid, false);
  v_cycle_start := case when v_is_joining then v_student.join_date
                        else genalpha.student_paid_through_date(v_student.id) end;
  v_to_date     := (v_cycle_start + make_interval(months => v_months))::date;

  if exists (
    select 1 from payments p
     where p.tenant_id = 'genalpha'
       and p.member_id = v_member
       and p.kind = case when v_is_joining then 'admission' else 'renewal' end
       and p.period_from = v_cycle_start
  ) then
    raise exception 'This player already has a payment for the current cycle.';
  end if;

  -- The itemisation, not the price. What the family paid is v_amount;
  -- this only says how it splits, and it goes in payments.breakdown —
  -- the column added in 2026-08-10q for exactly this.
  v_admission_fee := case when v_plan = 'special' then 0 else 500 end;
  v_jersey        := greatest(coalesce(v_student.jersey_pairs, 0), 0) * 750;
  v_coaching      := greatest(v_amount - v_admission_fee - v_jersey, 0);

  -- ---- THE MONEY. One write path, the platform's. ----
  -- record_fee_payment writes the payment, rolls enrollments.renewal_on
  -- forward, applies coverage and writes the timeline. All four of those
  -- were hand-rolled in the pre-merge version.
  v_result := record_fee_payment(
    'genalpha',
    v_enrollment,
    v_amount,
    case when v_months in (1,3,6,12) then v_months else null end,
    'UPI',
    case when v_is_joining then 'admission' else 'renewal' end,
    v_paid_on,
    nullif(v_reference, ''),
    'paid',
    coalesce(nullif(p_confirmed_by, ''), 'WhatsApp staff'),
    concat(case when v_is_joining then 'Confirmed conversational joining payment. '
                else 'Confirmed conversational renewal. ' end,
           coalesce(v_draft->>'comments', ''))
  );
  v_payment_id := (v_result->>'payment_id')::bigint;

  -- The two things record_fee_payment has no argument for.
  update payments
     set proof_path = nullif(v_proof_path, ''),
         breakdown  = jsonb_build_object('coaching', v_coaching,
                                         'admission', v_admission_fee,
                                         'kit', v_jersey)
   where id = v_payment_id;

  -- ---- GenAlpha's own per-student detail ----
  update genalpha.student_details
     set fees_paid        = true,
         fee_plan         = v_plan,
         amount_paid      = case when v_is_joining then v_amount else amount_paid end,
         payment_status   = 'paid',
         coaching_fee     = case when v_is_joining then v_coaching else coaching_fee end,
         admission_fee    = case when v_is_joining then v_admission_fee else admission_fee end,
         jersey_amount    = case when v_is_joining then v_jersey else jersey_amount end,
         total_fee_amount = case when v_is_joining then v_amount else total_fee_amount end,
         renewals         = case when v_is_joining then renewals else (
                              select array_agg(distinct x order by x)
                                from unnest(coalesce(renewals, '{}'::date[]) || array[v_cycle_start]) x
                            ) end,
         updated_by       = coalesce(nullif(p_confirmed_by, ''), 'WhatsApp staff')
   where member_id = v_member;

  -- Paying reinstates a discontinued player.
  update members
     set status          = case when status = 'discontinued' then 'active' else status end,
         rejoined_at     = case when status = 'discontinued' then v_paid_on else rejoined_at end,
         discontinued_on = case when status = 'discontinued' then null else discontinued_on end,
         updated_by      = coalesce(nullif(p_confirmed_by, ''), 'WhatsApp staff')
   where id = v_member;

  if v_is_joining and v_student.admission_id is not null then
    update genalpha.admissions
       set fees_paid = true, amount_paid = v_amount, fee_plan = v_plan,
           coaching_fee = v_coaching, admission_fee = v_admission_fee,
           jersey_amount = v_jersey, total_fee_amount = v_amount,
           payment_verification_status = 'verified'
     where id = v_student.admission_id;
  end if;

  update genalpha.admission_intake_sessions
     set status                  = 'confirmed',
         renewal_payment_id      = v_payment_id,
         confirmation_message_id = coalesce(p_confirmation_message_id, ''),
         confirmed_by            = coalesce(nullif(p_confirmed_by, ''), 'WhatsApp staff'),
         confirmed_at            = coalesce(confirmed_at, now()),
         error_code = '', error_message = ''
   where id = v_session.id;

  return query
    select v_payment_id, v_student.id, v_student.name, v_student.reg_no,
           (v_result->>'period_from')::date, (v_result->>'period_to')::date;
end $$;

comment on function genalpha.finalize_renewal_intake(uuid, text, text) is
  'Confirms a conversational renewal. GenAlpha owns the validation; record_fee_payment() owns the money.';

-- ---- backfill_intake_payment_proof_path: same job, platform tables ----
create or replace function genalpha.backfill_intake_payment_proof_path(
  p_session_id uuid,
  p_proof_path text
)
returns text
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare
  v_payment      payments%rowtype;
  v_member       bigint;
  v_existing_ids bigint[] := '{}';
  v_old_marker   text;
  v_new_marker   text;
begin
  if coalesce(btrim(p_proof_path), '') = '' then
    raise exception 'Canonical payment proof path is required';
  end if;

  select p.* into v_payment
    from genalpha.admission_intake_sessions s
    join payments p on p.id = s.renewal_payment_id and p.tenant_id = 'genalpha'
   where s.id = p_session_id
     for update of p;
  if not found then
    raise exception 'Confirmed renewal payment not found for intake session %', p_session_id;
  end if;

  if v_payment.proof_path is not distinct from p_proof_path then
    return p_proof_path;
  end if;

  v_member := v_payment.member_id;

  select coalesce(array_agg(id), '{}') into v_existing_ids
    from member_timeline where tenant_id = 'genalpha' and member_id = v_member;

  v_old_marker := 'payment-proofs/' || coalesce(v_payment.proof_path, '');
  v_new_marker := 'payment-proofs/' || p_proof_path;

  update payments set proof_path = p_proof_path where id = v_payment.id;

  -- Relocating a proof is maintenance, not an event worth a timeline row.
  -- Delete only what this transaction just created; keep the original.
  delete from member_timeline
   where tenant_id = 'genalpha'
     and member_id = v_member
     and kind = 'payment_updated'
     and not (id = any (v_existing_ids))
     and coalesce(body, '') like '%' || v_new_marker || '%';

  if coalesce(v_payment.proof_path, '') <> '' then
    update member_timeline
       set body = replace(body, v_old_marker, v_new_marker)
     where tenant_id = 'genalpha'
       and member_id = v_member
       and coalesce(body, '') like '%' || v_old_marker || '%';
  end if;

  return p_proof_path;
end $$;

-- ------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------
-- The default grant on a new function is to PUBLIC, so every one of these
-- is anon-callable until revoked — and revoking `anon` alone does
-- nothing. These are SECURITY DEFINER, so RLS does not apply inside them
-- and the grant is the entire gate.
--
-- service_role ONLY. The edge function is the sole caller and it holds
-- the service key; nothing in GenAlpha's app references any of these
-- names. `authenticated` is deliberately excluded: these functions
-- hardcode tenant 'genalpha' and take no p_tenant, so there is nothing to
-- assert_staff() against, and a signed-in staff member at Raj could
-- otherwise confirm a payment for a GenAlpha family. That is the shape
-- tenant_reach_audit() was written for.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'genalpha'
       and p.proname in ('normalize_admission_intake_slot',
                         'get_or_create_admission_intake_session',
                         'finalize_admission_intake',
                         'finalize_renewal_intake',
                         'backfill_intake_payment_proof_path',
                         'student_paid_through_date')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant  execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; d1 date; d2 date; v_id uuid;
begin
  -- all six exist
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'genalpha'
     and p.proname in ('normalize_admission_intake_slot','get_or_create_admission_intake_session',
                       'finalize_admission_intake','finalize_renewal_intake',
                       'backfill_intake_payment_proof_path','student_paid_through_date');
  if n <> 6 then raise exception 'expected 6 genalpha intake functions, got %', n; end if;

  -- none of them is reachable by anon or by another tenant's staff
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'genalpha'
     and p.proname in ('normalize_admission_intake_slot','get_or_create_admission_intake_session',
                       'finalize_admission_intake','finalize_renewal_intake',
                       'backfill_intake_payment_proof_path','student_paid_through_date')
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if n <> 0 then raise exception '% intake function(s) still reachable by anon/authenticated', n; end if;

  -- ...but service_role, the one caller, can still reach every one
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'genalpha'
     and p.proname in ('normalize_admission_intake_slot','get_or_create_admission_intake_session',
                       'finalize_admission_intake','finalize_renewal_intake',
                       'backfill_intake_payment_proof_path','student_paid_through_date')
     and has_function_privilege('service_role', p.oid, 'execute');
  if n <> 6 then raise exception 'only % of 6 reachable by service_role — the caller is locked out', n; end if;

  -- The slot normaliser is pure; assert on content so a broken port shows.
  if genalpha.normalize_admission_intake_slot('6:00 AM - 7:30 AM') <> '6AM'
     or genalpha.normalize_admission_intake_slot('5:30pm') <> '5:30PM'
     or genalpha.normalize_admission_intake_slot('nonsense') <> '' then
    raise exception 'normalize_admission_intake_slot does not agree with the original';
  end if;

  -- student_paid_through_date must equal renewal_on for a real player,
  -- and must be a date the platform actually holds — not null for all.
  select d.legacy_uuid into v_id
    from genalpha.student_details d
    join enrollments e on e.member_id = d.member_id and e.tenant_id='genalpha'
   where e.renewal_on is not null limit 1;
  if v_id is null then raise exception 'no genalpha player has a renewal date to test against'; end if;

  select genalpha.student_paid_through_date(v_id) into d1;
  select e.renewal_on into d2 from enrollments e
    join genalpha.student_details d on d.member_id = e.member_id
   where d.legacy_uuid = v_id and e.tenant_id='genalpha';
  if d1 is distinct from d2 then
    raise exception 'paid-through says % but renewal_on says %', d1, d2;
  end if;

  -- and it answers for every player, not just one
  select count(*) into n from genalpha.student_details d
   where genalpha.student_paid_through_date(d.legacy_uuid) is null;
  if n > 0 then raise exception '% players have no paid-through date', n; end if;

  raise notice 'six intake RPCs live in genalpha, service_role only';
end $$;
