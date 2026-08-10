-- ============================================================
-- 2026-08-11s · Put GenAlpha's payments into platform vocabulary
-- scope: shared
--
-- Found while porting the admission-intake RPCs, and it is a defect in my
-- own merge. The platform's convention, which Raj follows, is:
--
--     mode = HOW they paid      UPI, Cash, Bank
--     kind = WHAT it was for    renewal, admission, custom
--
-- The merge inverted it for GenAlpha: the purpose went into `mode`
-- (joining/renewal/jersey) and `kind` got a generic 'fee'/'merchandise'.
-- The genalpha.student_payments view then mapped `mode AS payment_type`,
-- which made the app look right and hid the inversion completely.
--
-- It stayed invisible because nothing had written a genalpha payment
-- since the merge. The moment one does — and finalize_renewal_intake is
-- about to, through record_fee_payment() — the new row gets mode='UPI',
-- kind='renewal', and the view renders payment_type='UPI' next to 130
-- rows saying 'renewal'. Two vocabularies in one column.
--
-- record_fee_payment() is also strict about this: kind must be one of
-- renewal/admission/custom, so 'fee' is not a value the one write path
-- can even produce. The merged rows were reachable only because they were
-- inserted directly.
--
-- Three other things this fixes, all consequences of the same inversion:
--   * payments.enrollment_id is null on all 131 rows, so
--     apply_payment_coverage() and enrollment_payment_summary() see
--     nothing for GenAlpha. Each member has exactly one enrollment, so
--     the link is derivable with no ambiguity.
--   * the four jersey rows carry months=1, meaning a T-shirt bought a
--     month of coaching as far as coverage is concerned.
--   * admission_intake_sessions.renewal_payment_id is a uuid holding
--     GenAlpha's old payment ids, which now point at nothing.
-- ============================================================

-- ------------------------------------------------------------
-- 1. mode and kind, the right way round
-- ------------------------------------------------------------
-- Every GenAlpha family paid by UPI (student_details.payment_method is
-- 'UPI' for all 81), so the mode is not being guessed at.
update payments p
   set kind = case p.mode when 'renewal' then 'renewal'
                          when 'joining' then 'admission'
                          when 'jersey'  then 'custom' end,
       mode = 'UPI',
       -- A jersey buys no coaching time. months=1 made it buy a month.
       months = case when p.mode = 'jersey' then null else p.months end
 where p.tenant_id = 'genalpha'
   and p.kind in ('fee', 'merchandise');

-- 'admission' rather than 'renewal' for the joining payment is the same
-- call Raj made, and record_fee_payment() explicitly supports a joining
-- fee that also covers months — that was a bug it already fixed, and its
-- comment says so: "THE MONTHS BUY THE COVERAGE, NOT THE LABEL."

-- ------------------------------------------------------------
-- 2. Link every payment to its enrollment
-- ------------------------------------------------------------
update payments p
   set enrollment_id = e.id
  from enrollments e
 where p.tenant_id = 'genalpha'
   and e.tenant_id = 'genalpha'
   and e.member_id = p.member_id
   and p.enrollment_id is null;

-- ------------------------------------------------------------
-- 3. renewal_payment_id: uuid -> bigint, remapped not dropped
-- ------------------------------------------------------------
-- The six existing values are GenAlpha's old payment uuids. Each matches
-- exactly one platform payment on (member, amount, date, reference) —
-- verified 1:1 before writing this, not assumed. Dropping them would have
-- been easier and would have quietly broken the "already finalized" path
-- for six sessions.
alter table genalpha.admission_intake_sessions
  add column if not exists renewal_payment_bigint bigint;

update genalpha.admission_intake_sessions s
   set renewal_payment_bigint = p.id
  from genalpha.student_details d
  join payments p on p.member_id = d.member_id and p.tenant_id = 'genalpha'
 where s.renewal_payment_id is not null
   and d.legacy_uuid = s.matched_student_id
   and p.on_date  = (s.draft->'payment'->>'payment_date')::date
   and p.amount   = round((s.draft->'payment'->>'amount')::numeric);

do $$
declare n int;
begin
  select count(*) into n from genalpha.admission_intake_sessions
   where renewal_payment_id is not null and renewal_payment_bigint is null;
  if n > 0 then
    raise exception '% session(s) lost their payment link in the remap', n;
  end if;
end $$;

alter table genalpha.admission_intake_sessions drop column renewal_payment_id;
alter table genalpha.admission_intake_sessions
  rename column renewal_payment_bigint to renewal_payment_id;

comment on column genalpha.admission_intake_sessions.renewal_payment_id is
  'public.payments.id. Was a uuid pointing at GenAlpha''s own payments table before the merge; remapped in 2026-08-11s.';

-- ------------------------------------------------------------
-- 4. The view has to map back, or the app sees the new vocabulary
-- ------------------------------------------------------------
-- GenAlpha's app reads payment_type expecting joining/renewal/jersey.
-- That is a label, and mapping labels is exactly what this view is for —
-- the storage underneath is now platform vocabulary.
drop view if exists genalpha.student_payments;
create view genalpha.student_payments
with (security_invoker = true) as
  select p.id::text                              as id,
         d.legacy_uuid                           as student_id,
         case p.kind when 'renewal'   then 'renewal'
                     when 'admission' then 'joining'
                     when 'custom'    then 'jersey'
                     else p.kind end             as payment_type,
         p.months                                as months_covered,
         p.period_from                           as cycle_start_date,
         p.amount,
         p.on_date                               as paid_on,
         p.note                                  as comment,
         p.collected_by                          as recorded_by,
         p.created_at,
         p.proof_path,
         p.ref                                   as payment_reference,
         p.status                                as verification_status,
         p.mode                                  as payment_method,
         p.kind
    from payments p
    join genalpha.student_details d on d.member_id = p.member_id
   where p.tenant_id = 'genalpha';

revoke all on genalpha.student_payments from public, anon;
grant select on genalpha.student_payments to authenticated, service_role;

comment on view genalpha.student_payments is
  'GenAlpha''s payment vocabulary over platform payments. payment_type is a LABEL mapped from kind; the stored value is the platform''s.';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v numeric;
begin
  -- nothing left in the old vocabulary
  select count(*) into n from payments
   where tenant_id='genalpha' and kind not in ('renewal','admission','custom');
  if n <> 0 then raise exception '% genalpha payments still outside platform kinds', n; end if;

  -- the counts must match what was there before, purpose for purpose
  select count(*) into n from payments where tenant_id='genalpha' and kind='renewal';
  if n <> 92 then raise exception 'expected 92 renewals, got %', n; end if;
  select count(*) into n from payments where tenant_id='genalpha' and kind='admission';
  if n <> 35 then raise exception 'expected 35 joining payments, got %', n; end if;
  select count(*) into n from payments where tenant_id='genalpha' and kind='custom';
  if n <> 4  then raise exception 'expected 4 jersey payments, got %', n; end if;

  -- MONEY MUST NOT MOVE. This migration relabels; if a rupee changed,
  -- something in the update was wrong.
  select sum(amount) into v from payments where tenant_id='genalpha';
  if v <> 495551 then raise exception 'genalpha money total changed to %', v; end if;

  -- every payment now reaches its enrollment
  select count(*) into n from payments where tenant_id='genalpha' and enrollment_id is null;
  if n <> 0 then raise exception '% genalpha payments still have no enrollment', n; end if;

  -- and no payment landed on another member's enrollment
  select count(*) into n from payments p join enrollments e on e.id = p.enrollment_id
   where p.tenant_id='genalpha' and e.member_id <> p.member_id;
  if n <> 0 then raise exception '% payments point at the wrong member''s enrollment', n; end if;

  -- jerseys buy no coaching time
  select count(*) into n from payments where tenant_id='genalpha' and kind='custom' and months is not null;
  if n <> 0 then raise exception 'a jersey still buys coaching months'; end if;

  -- the view still speaks GenAlpha to the app
  select count(*) into n from genalpha.student_payments where payment_type='renewal';
  if n <> 92 then raise exception 'the view shows % renewals, not 92', n; end if;
  select count(*) into n from genalpha.student_payments where payment_type='joining';
  if n <> 35 then raise exception 'the view shows % joining payments, not 35', n; end if;

  -- the six intake sessions kept their payment
  select count(*) into n from genalpha.admission_intake_sessions
   where renewal_payment_id is not null;
  if n <> 6 then raise exception 'expected 6 linked sessions, got %', n; end if;
  select count(*) into n from genalpha.admission_intake_sessions s
    join payments p on p.id = s.renewal_payment_id and p.tenant_id='genalpha'
   where s.renewal_payment_id is not null;
  if n <> 6 then raise exception 'only % of 6 session links resolve to a payment', n; end if;

  raise notice 'genalpha payments: 131 relabelled, 131 linked to enrollments, 6 sessions remapped, INR % unchanged', v;
end $$;
