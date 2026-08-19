-- Proves the manager's "payment received" press can settle an admission claim.
--
-- The failing statement was one line inside reconcile_admission_claim_from_payment:
--     set student_payment_id = new_row.id
-- new_row is a genalpha.student_payments row, whose id is TEXT over
-- public.payments.id bigint, and the column was uuid. This drives that exact
-- assignment with a realistic id rather than asserting on the catalogue,
-- because reading the column type would have passed before the migration too.
--
-- run-test.sh executes this inside a transaction it always rolls back.

do $$
declare
  v_admission uuid;
  v_student   uuid;
  v_claim     uuid;
  v_session   uuid;
  v_row       genalpha.student_payments;
  v_linked    text;
  v_status    text;
begin
  select id, coalesce(approved_member_id::text, '')::text
    into v_admission, v_status
    from genalpha.admissions
   order by created_at desc
   limit 1;
  if v_admission is null then
    raise exception 'no admission to build the fixture on';
  end if;

  select legacy_uuid into v_student from genalpha.student_details limit 1;
  if v_student is null then
    raise exception 'no student to build the fixture on';
  end if;

  -- session_id is NOT NULL and unique, so borrow one that has no claim yet.
  select s.id into v_session
    from genalpha.admission_intake_sessions s
   where not exists (
     select 1 from genalpha.admission_payment_claims c where c.session_id = s.id)
   limit 1;
  if v_session is null then
    raise exception 'no spare intake session to build the fixture on';
  end if;

  insert into genalpha.admission_payment_claims
    (session_id, admission_id, student_id, amount, verification_status, screenshot_status)
  values (v_session, v_admission, v_student, 3500, 'pending', 'successful')
  returning id into v_claim;

  -- A payment as the view presents it: a numeric id carried as text.
  v_row.id           := '4999999';
  v_row.student_id   := v_student;
  v_row.payment_type := 'joining';
  v_row.amount       := 3500;
  v_row.recorded_by  := 'Test harness';

  perform genalpha.reconcile_admission_claim_from_payment(v_row, v_row, 'INSERT');

  select student_payment_id, verification_status
    into v_linked, v_status
    from genalpha.admission_payment_claims where id = v_claim;

  if v_linked is distinct from '4999999' then
    raise exception 'claim did not link to the payment: got %', coalesce(v_linked, '(null)');
  end if;
  if v_status <> 'verified' then
    raise exception 'claim was not marked verified: %', v_status;
  end if;

  raise notice 'OK: a text payment id settles an admission claim';
end $$;
