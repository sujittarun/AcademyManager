-- ============================================================
-- 2026-08-12k · The two admission RPCs the migration left behind
-- scope: shared
--
-- Found by diffing every function, trigger, policy and cron job on the
-- legacy project against this one, rather than by noticing a symptom.
-- Of 31 legacy functions, 14 had no counterpart here; 12 of those are
-- trigger bodies whose behaviour the INSTEAD OF layer already provides.
-- These two are real, and both are reachable from the manager's screen.
--
-- 1. reject_admission — AND WHY REJECTING HAS BEEN DESTRUCTIVE
--
--    The RPC was never ported. Worse, the web app never called it even
--    on legacy: script.js does
--
--        supabaseClient.from("admissions").delete().eq("id", id)
--
--    so pressing Reject HARD DELETES the application — the child's name,
--    both parent phone numbers, the address, the consent and terms
--    record, and the reg_no that was consumed to create it. No audit
--    row, no reviewer, no reason, and nothing to answer a parent who
--    rings back asking what happened. An approval is recorded forever; a
--    rejection left no trace at all.
--
--    The legacy function is the correct behaviour: mark it rejected,
--    keep the row, record who and why. Ported here, and script.js is
--    repointed at it in the same change.
--
-- 2. verify_admission_payment_claim — REWRITTEN, NOT COPIED
--
--    This is the manager confirming a parent's payment screenshot at
--    admission, and it is money, so it cannot be copied verbatim. The
--    legacy version INSERTs straight into student_payments and then
--    patches the student row itself.
--
--    Here student_payments is a view whose INSTEAD OF trigger routes to
--    record_fee_payment(), which owns the renewal roll-forward, the
--    timeline entry and closing the reminder. Inserting through the view
--    is therefore not a shortcut — it is the house rule. The arithmetic
--    stays in Postgres and there is one write path for a fee.
--
--    approved_student_id is approved_member_id here; that rename is why
--    a verbatim port would have failed at runtime rather than at
--    creation, since plpgsql does not check bodies until they run.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Reject without destroying the application
-- ------------------------------------------------------------
create or replace function genalpha.reject_admission(
  p_admission_id uuid,
  p_reviewed_by  text default 'Manager',
  p_review_notes text default ''
)
returns void
language plpgsql
security definer
set search_path = genalpha, public
as $$
begin
  perform assert_staff_or_service('genalpha');

  update genalpha.admissions
     set review_status = 'rejected',
         reviewed_by   = coalesce(nullif(p_reviewed_by, ''), 'Manager'),
         reviewed_at   = now(),
         review_notes  = coalesce(p_review_notes, '')
   where id = p_admission_id
     and review_status <> 'approved';

  if not found then
    raise exception 'Admission not found or already approved.';
  end if;
end $$;

comment on function genalpha.reject_admission(uuid, text, text) is
  'Marks an admission rejected and keeps the record. Replaces the client-side DELETE, which destroyed the applicant name, parent phones, consent record and reg_no with no audit trail.';

revoke execute on function genalpha.reject_admission(uuid, text, text) from public, anon;
grant  execute on function genalpha.reject_admission(uuid, text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- 2. Verify an admission payment claim, through the money path
-- ------------------------------------------------------------
create or replace function genalpha.verify_admission_payment_claim(
  p_claim_id    uuid,
  p_verified_by text default 'Manager',
  p_paid_on     date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare
  v_claim      genalpha.admission_payment_claims%rowtype;
  v_admission  genalpha.admissions%rowtype;
  v_student    uuid;
  v_payment_id uuid;
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
end $$;

comment on function genalpha.verify_admission_payment_claim(uuid, text, date) is
  'Manager confirms a parent''s admission payment screenshot. Writes through genalpha.student_payments so record_fee_payment() owns the money, unlike the legacy version which inserted directly.';

revoke execute on function genalpha.verify_admission_payment_claim(uuid, text, date) from public, anon;
grant  execute on function genalpha.verify_admission_payment_claim(uuid, text, date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v_id uuid; v_before int; v_after int; v_status text;
begin
  -- both exist, neither is anon-callable
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='genalpha' and p.proname in ('reject_admission','verify_admission_payment_claim');
  if n <> 2 then raise exception 'expected 2 ported functions, found %', n; end if;

  if has_function_privilege('anon', 'genalpha.reject_admission(uuid,text,text)', 'execute')
     or has_function_privilege('anon', 'genalpha.verify_admission_payment_claim(uuid,text,date)', 'execute') then
    raise exception 'anon can execute a ported admission function';
  end if;

  -- reject marks rather than deletes, and the row survives
  select count(*) into v_before from genalpha.admissions;
  select id into v_id from genalpha.admissions
   where review_status not in ('approved','rejected') limit 1;

  if v_id is not null then
    perform genalpha.reject_admission(v_id, 'migration probe', 'probe');
    select review_status into v_status from genalpha.admissions where id = v_id;
    if v_status <> 'rejected' then raise exception 'reject did not mark the row'; end if;

    select count(*) into v_after from genalpha.admissions;
    if v_after <> v_before then
      raise exception 'rejecting removed % row(s) — it must never delete', v_before - v_after;
    end if;

    -- put the probe row back
    update genalpha.admissions
       set review_status = 'pending', reviewed_by = null,
           reviewed_at = null, review_notes = null
     where id = v_id;
    raise notice 'reject_admission marks and keeps the record (probe reverted)';
  else
    raise notice 'no un-reviewed admission to probe against; reject_admission created but not exercised';
  end if;

  -- an already-approved admission must be refused
  select id into v_id from genalpha.admissions where review_status = 'approved' limit 1;
  if v_id is not null then
    begin
      perform genalpha.reject_admission(v_id, 'probe', '');
      raise exception 'reject_admission accepted an already-approved admission';
    exception when others then
      if sqlerrm not like '%already approved%' then raise; end if;
    end;
    raise notice 'an approved admission cannot be rejected';
  end if;
end $$;
