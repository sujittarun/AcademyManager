-- ============================================================
-- 2026-08-12c · A jersey is not a month of coaching
-- scope: shared
--
-- Two money defects on the same line of the app, neither fired yet, both
-- arm on the next press of the +/- jersey control.
--
-- script.js:5974-6013 sends payment_type 'jersey' or 'jersey_refund' with
-- months_covered: 1 and an amount that is ALWAYS positive — Math.abs then
-- Math.max(x, 0). The direction lives entirely in payment_type.
--
--   1. genalpha.student_payments_write mapped 'jersey' to kind 'custom'
--      and then handed it to record_fee_payment with months = 1. That
--      function exists to roll enrollments.renewal_on forward and apply
--      coverage, so a Rs 750 shirt bought a month of coaching and marked
--      every open reminder for that family resolved.
--
--   2. 'jersey_refund' was not mapped at all and fell through to
--      'renewal'. Removing a pair therefore ADDED Rs 750 to revenue
--      instead of subtracting it — a 2x error — and bought the same free
--      month.
--
-- Merchandise now bypasses record_fee_payment entirely and is written
-- directly: months null, period_from = period_to = the payment date, so
-- there is no coverage to apply and nothing to roll forward. A refund is
-- stored as a negative amount, which is also why it cannot go through
-- record_fee_payment — that rejects anything <= 0.
--
-- Not a house-rule exception: the money is still computed in Postgres.
-- It is that a T-shirt is not a fee, and the one function that owns fees
-- has no correct behaviour for it.
-- ============================================================

CREATE OR REPLACE FUNCTION genalpha.student_payments_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_member bigint; v_enroll bigint; v_months int; v_kind text; v_result jsonb; v_id bigint;
  v_recent timestamptz; v_signed numeric;
begin
  if tg_op = 'DELETE' then
    perform genalpha.log_student_payment_life_timeline(old, old, 'DELETE');
    -- Reversal is not a delete. void_payment() writes the reversal, the
    -- timeline entry and pulls renewal_on back; a raw delete would leave
    -- the family's renewal date sitting on coverage they no longer have.
    perform void_payment('genalpha', old.id::bigint, 'Deleted from the GenAlpha app');
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;
  if v_member is null then
    raise exception 'No GenAlpha player with id %', new.student_id;
  end if;

  if tg_op = 'UPDATE' then
    new := genalpha.preserve_admission_claim_payment_values(new, old, 'UPDATE');
    -- Only the annotations are editable. Amounts and dates go through
    -- void-and-rerecord, so there is no path that changes money without
    -- the platform recomputing coverage.
    update payments
       set note        = coalesce(new.comment, note),
           proof_path  = coalesce(new.proof_path, proof_path),
           ref         = coalesce(new.payment_reference, ref),
           status      = coalesce(new.verification_status, status),
           collected_by = coalesce(new.recorded_by, collected_by)
     where id = old.id::bigint and tenant_id = 'genalpha';
    perform genalpha.log_student_payment_life_timeline(new, old, 'UPDATE');
    return new;
  end if;

  select e.id into v_enroll from enrollments e
   where e.tenant_id='genalpha' and e.member_id = v_member order by e.id limit 1;
  if v_enroll is null then
    raise exception 'That player has no enrollment to pay against.';
  end if;

  v_kind := case coalesce(new.payment_type, 'renewal')
              when 'joining'       then 'admission'
              when 'jersey'        then 'custom'
              when 'jersey_refund' then 'custom'
              else 'renewal' end;

  -- A refund is the same merchandise line with the sign flipped. The app
  -- sends a POSITIVE amount and puts the direction in payment_type
  -- (script.js:5990-5997 uses Math.abs then Math.max(x,0)), so unmapped
  -- it became a 'renewal' that ADDED the money instead of taking it off.
  v_signed := case when coalesce(new.payment_type,'') = 'jersey_refund'
                   then -abs(new.amount) else new.amount end;

  -- record_fee_payment only accepts 1/3/6/12. An off-ladder special (a
  -- 2- or 4-month block) passes null, which stores months_covered NULL —
  -- and the app then guesses the month count back from the amount, which
  -- credits 6 months for a 20,000 two-month renewal. So the ladder months
  -- go through as themselves and anything else is recorded as a custom
  -- payment carrying its real month count, set immediately below.
  v_months := case when coalesce(new.months_covered,1) in (1,3,6,12)
                   then new.months_covered else null end;

  -- ONE PAYMENT PER CYCLE. Player F had three renewals recorded in
  -- sixty seconds, each rolling renewal_on forward a month, because the
  -- app's duplicate check is a separate round trip: three rapid taps all
  -- pass it before the first insert lands. A client-side check cannot win
  -- that race; this one is inside the write.
  --
  -- The cycle is computed exactly as record_fee_payment will compute it —
  -- greatest(renewal_on, paid_on) — so the guard tests the row that is
  -- about to be created, not the one the app thinks it is creating.
  -- finalize_renewal_intake has had this check since the port; the app
  -- path never did.
  --
  -- Jersey and other custom payments are exempt: they buy no months and a
  -- family can legitimately buy two in a day.
  if v_kind <> 'custom' then
    select p.created_at into v_recent
      from payments p
     where p.tenant_id = 'genalpha'
       and p.member_id = v_member
       and p.kind = v_kind
       and p.amount = round(new.amount)
       and p.status <> 'void'
       and p.created_at > now() - interval '2 minutes'
     order by p.created_at desc limit 1;

    if v_recent is not null then
      raise exception
        'An identical % of Rs % was recorded for this player % seconds ago. Refresh to see it before recording another.',
        case when v_kind = 'admission' then 'joining fee' else 'renewal' end,
        round(new.amount),
        round(extract(epoch from (now() - v_recent)))
        using errcode = 'unique_violation';
    end if;
  end if;

  -- MERCHANDISE IS NOT A FEE. A jersey buys no coaching time, so it must
  -- not go through record_fee_payment at all: that function's entire job
  -- is rolling enrollments.renewal_on forward and applying coverage, and
  -- it defaults a null month count to the enrollment's plan_months — so a
  -- Rs 750 shirt bought a month of coaching and resolved every open
  -- reminder for that family. A refund could not go through it either,
  -- because it rejects an amount <= 0.
  if v_kind = 'custom' then
    insert into payments (tenant_id, name, type, detail, amount, mode, on_date, ref,
                          enrollment_id, member_id, centre_id, sport, months,
                          period_from, period_to, kind, status, collected_by, note, proof_path)
    select 'genalpha', m.name, 'Merchandise',
           coalesce(nullif(new.plan_type,''), 'jersey'),
           round(v_signed), coalesce(new.payment_method,'UPI'),
           coalesce(new.paid_on, ist_today()), nullif(new.payment_reference,''),
           e.id, v_member, e.centre_id, e.sport,
           null,                                   -- buys no months
           coalesce(new.paid_on, ist_today()),     -- and therefore no period
           coalesce(new.paid_on, ist_today()),
           'custom', 'paid', coalesce(new.recorded_by,'GenAlpha app'), new.comment,
           nullif(new.proof_path,'')
      from members m
      left join enrollments e on e.member_id = m.id and e.tenant_id='genalpha'
     where m.id = v_member
    returning id into v_id;

    update genalpha.student_details
       set jersey_pairs = coalesce(new.jersey_pairs, jersey_pairs),
           jersey_size  = coalesce(nullif(new.jersey_size,''), jersey_size)
     where member_id = v_member;

    perform genalpha.log_student_payment_life_timeline(new, new, 'INSERT');
    new.id := v_id::text;
    return new;
  end if;

  v_result := record_fee_payment(
    'genalpha', v_enroll, new.amount, v_months, coalesce(new.payment_method,'UPI'),
    v_kind, coalesce(new.paid_on, ist_today()), nullif(new.payment_reference,''),
    'paid', coalesce(new.recorded_by,'GenAlpha app'), new.comment);
  v_id := (v_result->>'payment_id')::bigint;

  update payments
     set proof_path = coalesce(nullif(new.proof_path,''), proof_path),
         months     = coalesce(v_months, greatest(coalesce(new.months_covered,1),1))
   where id = v_id;

  -- Joining-fee detail belongs to the student, not the payment.
  if new.payment_type = 'joining' then
    update genalpha.student_details
       set fees_paid        = true,
           payment_status   = 'paid',
           amount_paid      = coalesce(new.amount, amount_paid),
           coaching_fee     = coalesce(new.coaching_fee, coaching_fee),
           admission_fee    = coalesce(new.admission_fee, admission_fee),
           jersey_amount    = coalesce(new.jersey_amount, jersey_amount),
           total_fee_amount = coalesce(new.total_fee_amount, total_fee_amount),
           jersey_size      = coalesce(nullif(new.jersey_size,''), jersey_size),
           jersey_pairs     = coalesce(new.jersey_pairs, jersey_pairs)
     where member_id = v_member;
  elsif new.payment_type = 'renewal' then
    update genalpha.student_details
       -- renewals is JSONB, not date[]. 2026-08-11t's
       -- finalize_renewal_intake got this wrong and dry-ran clean,
       -- because plpgsql does not type-check a function body at creation
       -- time — it would have failed on the first WhatsApp renewal. Fixed
       -- there too, at the end of this file.
       set renewals = (
         select jsonb_agg(distinct x order by x)
           from jsonb_array_elements_text(
                  coalesce(renewals, '[]'::jsonb)
                  || jsonb_build_array(coalesce(new.cycle_start_date, ist_today())::text)) x)
     where member_id = v_member;
  end if;

  new.id := v_id::text;
  -- record_fee_payment already writes its own 'payment' timeline entry,
  -- so this adds GenAlpha's richer one on top: the plan label, the cycle
  -- and who took it, which is what its history screen renders.
  perform genalpha.log_student_payment_life_timeline(new, new, 'INSERT');
  perform genalpha.reconcile_admission_claim_from_payment(new, new, 'INSERT');
  return new;
end $function$;

-- ------------------------------------------------------------
-- Merchandise can be returned; a coaching fee cannot be negative
-- ------------------------------------------------------------
-- payments_amount_sane is `amount is null or amount >= 0`, and PLATFORM.md
-- lists that under "genuine data sanity — keep those". It is right about
-- fees: the platform reverses a fee with void_payment, not with a negative
-- row, and a negative coaching fee is always a mistake.
--
-- A returned jersey is different. It is not a reversal of a fee, it is
-- merchandise going back, and the money genuinely moves the other way. So
-- the constraint is narrowed to say exactly that rather than dropped:
-- negative is allowed only for kind='custom'.
--
-- This binds every tenant, which is correct — it is a statement about what
-- money can do, not about how GenAlpha sells shirts.
alter table public.payments drop constraint payments_amount_sane;
alter table public.payments add constraint payments_amount_sane
  check (amount is null or amount >= 0 or kind = 'custom');

-- ------------------------------------------------------------
-- The view: a refund reads back as a refund, and a void is not revenue
-- ------------------------------------------------------------
-- payment_type is derived from kind, so a negative custom row has to come
-- back as 'jersey_refund' or the app's own sign handling (script.js:1271)
-- stays dead code.
--
-- And voided payments were still being counted: the view had no status
-- filter, so a reversal left the money in the Revenue and Net tiles. A
-- voided payment is not a payment. It stays in public.payments, where the
-- audit trail belongs; it just stops being income.
drop view if exists genalpha.student_payments cascade;
create view genalpha.student_payments with (security_invoker = true) as
  select p.id::text                                as id,
         d.legacy_uuid                             as student_id,
         case
           when p.kind = 'custom' and p.amount < 0 then 'jersey_refund'
           when p.kind = 'custom'                  then 'jersey'
           when p.kind = 'renewal'                 then 'renewal'
           when p.kind = 'admission'               then 'joining'
           else p.kind end                         as payment_type,
         case
           when p.kind = 'custom'                     then 'jersey_pair'
           when d.fee_plan = 'special'                then 'special'
           when coalesce(p.months, 1) = 3             then 'quarterly'
           when coalesce(p.months, 1) = 6             then 'halfyearly'
           when coalesce(p.months, 1) = 1             then 'monthly'
           else 'custom' end                       as plan_type,
         p.months                                  as months_covered,
         p.period_from                             as cycle_start_date,
         p.amount,
         p.on_date                                 as paid_on,
         p.note                                    as comment,
         p.collected_by                            as recorded_by,
         p.created_at,
         p.proof_path,
         p.ref                                     as payment_reference,
         p.status                                  as verification_status,
         p.mode                                    as payment_method,
         p.kind,
         d.coaching_fee, d.admission_fee, d.jersey_amount,
         d.total_fee_amount, d.jersey_size, d.jersey_pairs
    from payments p
    join genalpha.student_details d on d.member_id = p.member_id
   where p.tenant_id = 'genalpha'
     and p.status <> 'void';

revoke all on genalpha.student_payments from public, anon;
grant select, insert, update, delete on genalpha.student_payments to authenticated, service_role;

-- ------------------------------------------------------------
-- Restore what the cascade took with it
-- ------------------------------------------------------------
-- `drop view ... cascade` also drops every function whose SIGNATURE names
-- the view's composite type — here the three helpers that take a
-- genalpha.student_payments row. They are recreated verbatim from their
-- live definitions rather than retyped, and the trigger that calls them
-- is rebuilt below.

CREATE OR REPLACE FUNCTION genalpha.log_student_payment_life_timeline(new_row genalpha.student_payments, old_row genalpha.student_payments, p_op text DEFAULT 'UPDATE'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_row genalpha.student_payments%rowtype;
  v_event_type text;
  v_title text;
  v_actor text;
begin
  if p_op = 'DELETE' then
    v_row := old_row;
    v_event_type := 'payment_deleted';
    v_title := case when old_row.payment_type = 'renewal' then 'Renewal payment deleted' else 'Payment deleted' end;
    v_actor := coalesce(nullif(old_row.recorded_by, ''), 'System');
  elsif p_op = 'UPDATE' then
    v_row := new_row;
    v_event_type := 'payment_updated';
    v_title := case when new_row.payment_type = 'renewal' then 'Renewal payment updated' else 'Payment updated' end;
    v_actor := coalesce(nullif(new_row.recorded_by, ''), 'System');
  else
    v_row := new_row;
    v_event_type := case
      when new_row.payment_type = 'joining' then 'joining_fee_paid'
      when new_row.payment_type in ('jersey', 'jersey_refund') then 'jersey_payment'
      else 'renewal_paid'
    end;
    v_title := case
      when new_row.payment_type = 'joining' then 'Joining fee recorded'
      when new_row.payment_type = 'renewal' then 'Renewal fee paid'
      when new_row.payment_type = 'jersey_refund' then 'Jersey refund recorded'
      when new_row.payment_type = 'jersey' then 'Jersey payment recorded'
      else 'Fee payment recorded'
    end;
    v_actor := coalesce(nullif(new_row.recorded_by, ''), 'System');
  end if;

  insert into genalpha.student_timeline (
    student_id,
    event_type,
    event_date,
    title,
    details,
    changed_by
  )
  values (
    v_row.student_id,
    v_event_type,
    coalesce(v_row.paid_on, current_date),
    v_title,
    concat(
      'Rs ', coalesce(v_row.amount, 0),
      ' • ', coalesce(nullif(v_row.plan_type, ''), 'plan not set'),
      ' • ', coalesce(v_row.months_covered, 0), ' month',
      case when coalesce(v_row.months_covered, 0) = 1 then '' else 's' end,
      ' • cycle from ', coalesce(v_row.cycle_start_date::text, 'not set'),
      case when coalesce(nullif(v_row.comment, ''), '') <> '' then concat(' • ', v_row.comment) else '' end,
      case when coalesce(nullif(v_row.proof_path, ''), '') <> '' then concat(' • payment-proofs/', v_row.proof_path) else '' end
    ),
    v_actor
  );

  if p_op = 'DELETE' then
    return;
  end if;
  return;
end;
$function$;
revoke execute on function genalpha.log_student_payment_life_timeline(genalpha.student_payments, genalpha.student_payments, text) from public, anon;

CREATE OR REPLACE FUNCTION genalpha.preserve_admission_claim_payment_values(new_row genalpha.student_payments, old_row genalpha.student_payments, p_op text DEFAULT 'UPDATE'::text)
 RETURNS genalpha.student_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_claim genalpha.admission_payment_claims%rowtype;
  v_admission genalpha.admissions%rowtype;
begin
  if new_row.payment_type <> 'joining' then
    return new_row;
  end if;

  select * into v_claim
  from genalpha.admission_payment_claims claim
  where claim.student_id = new_row.student_id
    and claim.verification_status in ('pending', 'conflict')
    and claim.student_payment_id is null
  order by claim.created_at
  limit 1
  for update;

  if not found then
    return new_row;
  end if;

  select * into v_admission
  from genalpha.admissions admission
  where admission.id = v_claim.admission_id;

  if found then
    new_row.plan_type := v_admission.fee_plan;
    new_row.cycle_start_date := v_admission.join_date;
    new_row.coaching_fee := v_admission.coaching_fee;
    new_row.admission_fee := v_admission.admission_fee;
    new_row.jersey_amount := v_admission.jersey_amount;
    new_row.total_fee_amount := v_admission.total_fee_amount;
    new_row.jersey_size := v_admission.jersey_size;
    new_row.jersey_pairs := v_admission.jersey_pairs;
  end if;

  new_row.amount := v_claim.amount;
  new_row.paid_on := coalesce(v_claim.payment_date, new_row.paid_on);
  new_row.proof_path := coalesce(nullif(v_claim.proof_path, ''), new_row.proof_path);
  new_row.payment_reference := coalesce(
    nullif(v_claim.payment_reference, ''),
    nullif(v_claim.utr, ''),
    new_row.payment_reference
  );

  return new_row;
end;
$function$;
revoke execute on function genalpha.preserve_admission_claim_payment_values(genalpha.student_payments, genalpha.student_payments, text) from public, anon;

CREATE OR REPLACE FUNCTION genalpha.reconcile_admission_claim_from_payment(new_row genalpha.student_payments, old_row genalpha.student_payments, p_op text DEFAULT 'UPDATE'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_claim_id uuid;
  v_admission_id uuid;
begin
  if new_row.payment_type <> 'joining' then return; end if;

  select c.id, c.admission_id into v_claim_id, v_admission_id
  from genalpha.admission_payment_claims c
  where c.student_id = new_row.student_id
    and c.verification_status in ('pending', 'conflict')
    and c.student_payment_id is null
  order by c.created_at
  limit 1
  for update;

  if v_claim_id is not null then
    update genalpha.admission_payment_claims
    set student_payment_id = new_row.id, verification_status = 'verified',
        verified_by = new_row.recorded_by, verified_at = now()
    where id = v_claim_id;

    update genalpha.admissions
    set fees_paid = true, amount_paid = new_row.amount,
        payment_verification_status = 'verified'
    where id = v_admission_id;
  end if;
  return;
end;
$function$;
revoke execute on function genalpha.reconcile_admission_claim_from_payment(genalpha.student_payments, genalpha.student_payments, text) from public, anon;

create trigger student_payments_iud instead of insert or update or delete
  on genalpha.student_payments for each row execute function genalpha.student_payments_write();

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v_uuid uuid; v_member bigint; v_enroll bigint; v_pay text;
  n0 int; n int; r0 date; r1 date; v_amt numeric; v_type text;
begin
  select count(*) into n0 from payments where tenant_id='genalpha';

  insert into genalpha.students
    (name, age, join_date, time_slot, fee_plan, coaching_fee, admission_fee,
     jersey_amount, total_fee_amount, jersey_size, jersey_pairs, renewals,
     added_by, updated_by, discontinued, father_guardian_name, parent_contact_no,
     whatsapp_contact_status, alternate_contact_no, fees_paid, amount_paid)
  values ('ZZ Jersey Probe', 9, current_date, '6AM', 'monthly', 3500, 500,
          0, 4000, 'M', 1, '[]'::jsonb, 'probe', 'probe', false,
          'ZZ Probe Parent', '9000000004', 'active', '', false, 0)
  returning id into v_uuid;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_uuid;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, joined_on, renewal_on, status)
  select 'genalpha', v_member, e.centre_id, e.batch_id, 'cricket',
         1, current_date, current_date, 'active'
    from enrollments e where e.tenant_id='genalpha' order by e.id limit 1;
  select renewal_on into r0 from enrollments where member_id = v_member;

  -- A JERSEY MUST NOT MOVE THE RENEWAL DATE. This is the whole migration.
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, comment, recorded_by, jersey_pairs)
  values (v_uuid, 'jersey', 'jersey_pair', current_date, 1, 750, current_date,
          'pair added', 'probe', 2)
  returning id into v_pay;

  select renewal_on into r1 from enrollments where member_id = v_member;
  if r1 <> r0 then
    raise exception 'a jersey moved renewal_on from % to %', r0, r1;
  end if;
  if (select months from payments where id = v_pay::bigint) is not null then
    raise exception 'the jersey payment claims coaching months';
  end if;

  -- A REFUND MUST SUBTRACT.
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, comment, recorded_by, jersey_pairs)
  values (v_uuid, 'jersey_refund', 'jersey_pair', current_date, 1, 750, current_date,
          'pair removed', 'probe', 1);

  select sum(amount) into v_amt from payments where member_id = v_member and kind='custom';
  if v_amt <> 0 then
    raise exception 'a jersey bought then refunded nets Rs %, expected 0', v_amt;
  end if;

  -- and it reads back as a refund, not a renewal
  select payment_type into v_type from genalpha.student_payments
   where student_id = v_uuid and amount < 0;
  if v_type is distinct from 'jersey_refund' then
    raise exception 'the refund reads back as %, not jersey_refund', v_type;
  end if;

  select renewal_on into r1 from enrollments where member_id = v_member;
  if r1 <> r0 then raise exception 'the refund moved renewal_on'; end if;

  -- VOIDED PAYMENTS ARE NOT REVENUE.
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, recorded_by)
  values (v_uuid, 'renewal', 'monthly', current_date, 1, 3500, current_date, 'probe')
  returning id into v_pay;
  perform void_payment('genalpha', v_pay::bigint, 'probe void');
  if exists (select 1 from genalpha.student_payments where id = v_pay) then
    raise exception 'a voided payment still shows in the app''s payment view';
  end if;
  if not exists (select 1 from payments where id = v_pay::bigint and status='void') then
    raise exception 'the voided payment vanished from public.payments — the trail is gone';
  end if;

  -- clean up
  delete from payments        where member_id = v_member;
  delete from member_timeline where member_id = v_member;
  delete from enrollments     where member_id = v_member;
  delete from genalpha.students where id = v_uuid;
  select count(*) into n from payments where tenant_id='genalpha';
  if n <> n0 then raise exception 'the probe left % payments behind', n - n0; end if;

  raise notice 'jersey buys no months, a refund subtracts, a void is not revenue';
end $$;
