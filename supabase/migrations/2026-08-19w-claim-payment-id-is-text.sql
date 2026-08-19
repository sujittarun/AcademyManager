-- ============================================================
-- 2026-08-19w · An admission payment claim points at a bigint payment
-- scope: shared
--
-- Confirming a pending verification failed with
--
--   column "student_payment_id" is of type uuid but expression is of type text
--
-- genalpha.admission_payment_claims.student_payment_id was typed uuid when
-- GenAlpha owned its own payments table with uuid keys. Since the platform
-- migration, money lives in public.payments with a bigint id, exposed through
-- genalpha.student_payments as TEXT. So:
--
--   reconcile_admission_claim_from_payment:
--     set student_payment_id = new_row.id     -- text -> uuid column
--
-- fires on any payment recorded for a student who still has an open claim,
-- which is exactly what the manager's "payment received" button does: it
-- inserts into the student_payments view, the INSTEAD OF trigger calls
-- record_fee_payment, and this trigger then runs. The whole transaction rolls
-- back, so no money was taken -- but the confirmation could never complete.
--
-- The column becomes text rather than bigint because three claims still carry
-- legacy GenAlpha payment uuids from before the migration; text holds both
-- those and ids like '4121' without losing anything. The partial unique index
-- that stops one payment settling two claims is rebuilt by the ALTER.
--
-- verify_admission_payment_claim has the same fault one line deeper --
-- `v_payment_id uuid` receiving `returning id` from a text column -- so it is
-- rebuilt to return text. It has no callers in any client today (checked
-- across GenAlpha, GenAlphaApp and AcademyManager), which is why the failure
-- surfaced through the trigger instead. Changing a return type needs
-- DROP + CREATE, and a dropped function loses its grants, so they are restored
-- explicitly below: authenticated and service_role, never PUBLIC.
-- ============================================================

alter table genalpha.admission_payment_claims
  alter column student_payment_id type text using student_payment_id::text;

comment on column genalpha.admission_payment_claims.student_payment_id is
  'genalpha.student_payments.id (text over public.payments.id bigint). Older '
  'rows hold a pre-migration GenAlpha payment uuid, as text.';

drop function if exists genalpha.verify_admission_payment_claim(uuid, text, date);

CREATE OR REPLACE FUNCTION genalpha.verify_admission_payment_claim(p_claim_id uuid, p_verified_by text DEFAULT 'Manager'::text, p_paid_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_claim      genalpha.admission_payment_claims%rowtype;
  v_admission  genalpha.admissions%rowtype;
  v_student    uuid;
  v_payment_id text;   -- student_payments.id is text over payments.id bigint
  v_months     integer;
begin
  perform assert_staff_or_service('genalpha');

  select * into v_claim from genalpha.admission_payment_claims
   where id = p_claim_id for update;
  if not found then raise exception 'Payment claim not found.'; end if;

  -- Idempotent: a second press must not take the money twice. This is
  -- the same guard as the 2-minute renewal window, expressed as a link.
  if v_claim.student_payment_id is not null then
    return v_claim.student_payment_id;
  end if;

  if v_claim.screenshot_status in ('failed', 'pending', 'processing') then
    raise exception 'The payment screenshot does not show a completed payment.';
  end if;
  if coalesce(v_claim.amount, 0) <= 0 then
    raise exception 'Payment amount must be greater than zero.';
  end if;

  select * into v_admission from genalpha.admissions
   where id = v_claim.admission_id for update;
  if not found then raise exception 'Admission not found for this claim.'; end if;
  if v_admission.approved_member_id is null then
    raise exception 'Approve the admission before verifying its payment.';
  end if;

  -- The legacy body read approved_student_id, which does not exist here.
  select d.legacy_uuid into v_student
    from genalpha.student_details d
   where d.member_id = v_admission.approved_member_id;
  if v_student is null then
    raise exception 'Approved member % has no GenAlpha player record', v_admission.approved_member_id;
  end if;

  v_months := case v_admission.fee_plan
                when 'quarterly'  then 3
                when 'halfyearly' then 6
                else greatest(coalesce((v_claim.extracted_data->>'months_covered')::integer, 1), 1)
              end;

  -- Through the view, so the INSTEAD OF trigger hands it to
  -- record_fee_payment() — renewal roll-forward, timeline and reminder
  -- closure included. Never a direct insert into payments.
  insert into genalpha.student_payments (
    student_id, payment_type, plan_type, cycle_start_date, months_covered,
    amount, paid_on, comment, recorded_by, proof_path, payment_reference,
    payment_method, coaching_fee, admission_fee, jersey_amount,
    total_fee_amount, jersey_size, jersey_pairs
  ) values (
    v_student, 'joining', v_admission.fee_plan, v_admission.join_date, v_months,
    v_claim.amount, p_paid_on,
    concat_ws(' • ', 'Admission intake payment verified',
              nullif(v_claim.payment_reference, ''), nullif(v_claim.utr, '')),
    coalesce(nullif(p_verified_by, ''), 'Manager'),
    v_claim.proof_path,
    coalesce(nullif(v_claim.payment_reference, ''), nullif(v_claim.utr, '')),
    nullif(v_claim.payment_method, ''),
    v_admission.coaching_fee, v_admission.admission_fee, v_admission.jersey_amount,
    v_admission.total_fee_amount, v_admission.jersey_size, v_admission.jersey_pairs
  ) returning id into v_payment_id;

  update genalpha.students
     set fees_paid         = true,
         amount_paid       = v_claim.amount,
         payment_method    = coalesce(nullif(v_claim.payment_method, ''), payment_method),
         payment_reference = coalesce(nullif(v_claim.payment_reference, ''),
                                      nullif(v_claim.utr, ''), payment_reference),
         payment_status    = 'paid',
         updated_by        = coalesce(nullif(p_verified_by, ''), 'Manager')
   where id = v_student;

  update genalpha.admissions
     set fees_paid = true,
         amount_paid = v_claim.amount,
         payment_verification_status = 'verified'
   where id = v_admission.id;

  update genalpha.admission_payment_claims
     set student_id         = v_student,
         student_payment_id = v_payment_id,
         verification_status = 'verified',
         verified_by = coalesce(nullif(p_verified_by, ''), 'Manager'),
         verified_at = now()
   where id = v_claim.id;

  return v_payment_id;
end $function$
;


revoke execute on function genalpha.verify_admission_payment_claim(uuid, text, date) from public, anon;
grant  execute on function genalpha.verify_admission_payment_claim(uuid, text, date) to authenticated, service_role;

do $$
declare v_type text; v_ret text; v_acl text; v_idx int;
begin
  select data_type into v_type from information_schema.columns
   where table_schema='genalpha' and table_name='admission_payment_claims'
     and column_name='student_payment_id';
  if v_type <> 'text' then
    raise exception 'student_payment_id is still %', v_type;
  end if;

  select pg_get_function_result(p.oid), coalesce(p.proacl::text,'(default)')
    into v_ret, v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='genalpha' and p.proname='verify_admission_payment_claim';
  if v_ret <> 'text' then raise exception 'verify_admission_payment_claim returns %', v_ret; end if;
  if v_acl like '%=X/%' and v_acl not like '%authenticated=X%' then
    raise exception 'authenticated lost execute on verify_admission_payment_claim';
  end if;
  -- A SECURITY DEFINER function anon can execute reads whatever tenant the
  -- caller names. The default grant after CREATE is PUBLIC, so this is the
  -- check that matters, not the revoke above.
  if has_function_privilege('anon', 'genalpha.verify_admission_payment_claim(uuid, text, date)', 'execute') then
    raise exception 'anon can execute verify_admission_payment_claim';
  end if;

  select count(*) into v_idx from pg_indexes
   where schemaname='genalpha' and tablename='admission_payment_claims'
     and indexname='admission_payment_claims_student_payment_id_key';
  if v_idx <> 1 then
    raise exception 'the one-payment-per-claim index did not survive the type change';
  end if;

  raise notice 'admission_payment_claims.student_payment_id is text; verify fn returns text';
end $$;
