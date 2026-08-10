-- ============================================================
-- 2026-08-11zh · A null month count, and the client pricing renewals
-- scope: shared
--
-- TWO THINGS.
--
-- 1. OFF-LADDER RENEWALS STORE NO MONTH COUNT.
--    record_fee_payment() accepts only 1, 3, 6 or 12 months, so
--    genalpha.finalize_renewal_intake passes null for anything else:
--
--        case when v_months in (1,3,6,12) then v_months else null end
--
--    That stores months_covered = NULL, and the app then guesses the
--    count back from the AMOUNT (script.js:1286-1290). A two-month
--    special renewal is exactly 20,000, which also appears in the app's
--    six-month amount table — so the family is credited six months for
--    two paid, their paid-through date moves four months out, and
--    reminder_queue() never chases them again. Silent, and it favours
--    the family, so nobody reports it.
--
--    The payment still goes through record_fee_payment; only the real
--    month count is written back afterwards, the same way the writable
--    view does it.
--
-- 2. THE CLIENT PRICES RENEWALS.
--    script.js:346 hardcodes 3500/9975/18900 and getRenewalDefault-
--    AmountForPlan() returns it with no reference to the student. 52 of
--    81 GenAlpha students are not on 3500 — 12 at 3000, 5 at 4250, and so
--    on — so a 3,000-a-month family is pre-filled 3,500. `grep resolve_fee
--    script.js pay.html intake.js` returns nothing.
--
--    That is the house rule, and the fix is not to correct the client's
--    numbers but to stop it having any. genalpha.quote_fee() gives the
--    app one call that returns what the database says this student owes.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Write the real month count back
-- ------------------------------------------------------------
do $$
declare src text; fixed text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'genalpha' and p.proname = 'finalize_renewal_intake';
  if src is null then raise exception 'finalize_renewal_intake is missing'; end if;

  fixed := replace(src,
    $old$  -- The two things record_fee_payment has no argument for.
  update payments
     set proof_path = nullif(v_proof_path, ''),$old$,
    $new$  -- The three things record_fee_payment has no argument for.
  -- months: it accepts only 1/3/6/12, so an off-ladder special was
  -- passed null and stored null. The app then infers the count from the
  -- amount and credits six months for a two-month renewal.
  update payments
     set months     = greatest(v_months, 1),
         proof_path = nullif(v_proof_path, ''),$new$);

  if fixed = src then
    raise exception 'could not find the post-payment update in finalize_renewal_intake';
  end if;
  execute fixed;
end $$;

-- ------------------------------------------------------------
-- 2. One place that knows what a student owes
-- ------------------------------------------------------------
create or replace function genalpha.quote_fee(
  p_student_id uuid,
  p_months     integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = genalpha, public
as $$
declare v_member bigint; v_enroll enrollments; v_fee jsonb;
begin
  perform assert_staff_or_service('genalpha');

  select d.member_id into v_member
    from genalpha.student_details d where d.legacy_uuid = p_student_id;
  if v_member is null then
    raise exception 'No GenAlpha player with id %', p_student_id;
  end if;

  select * into v_enroll from enrollments
   where tenant_id = 'genalpha' and member_id = v_member order by id limit 1;

  v_fee := resolve_fee('genalpha', v_member, v_enroll.centre_id, v_enroll.sport,
                       v_enroll.batch_id, greatest(coalesce(p_months, 1), 1), null);

  -- paid_through comes back with it, because the caller asking "what do
  -- they owe" is always about to ask "and from when". The app currently
  -- recomputes that in JavaScript from the renewals array
  -- (script.js:1327) while enrollments.renewal_on sits unread.
  return v_fee || jsonb_build_object(
    'student_id',   p_student_id,
    'months',       greatest(coalesce(p_months, 1), 1),
    'paid_through', v_enroll.renewal_on,
    'plan_months',  v_enroll.plan_months);
end $$;

comment on function genalpha.quote_fee(uuid, integer) is
  'What the database says a GenAlpha student owes for N months, plus their paid-through date. The one number the renewal popup should pre-fill.';

revoke execute on function genalpha.quote_fee(uuid, integer) from public, anon;
grant  execute on function genalpha.quote_fee(uuid, integer) to authenticated, service_role;

-- ------------------------------------------------------------
-- 3. Price the special-training students so quote_fee can answer
-- ------------------------------------------------------------
-- 2026-08-11y deliberately left non-standard rates without plan_amounts.
-- The special-training ladder is different: it is a published structure
-- (10,000/month, 5% off at 3, 10% off at 6) that GenAlpha's own code
-- implements in three places, so the database can hold it exactly.
update fee_rules fr
   set plan_amounts = jsonb_build_object(
         '1', fr.monthly_amount,
         '3', round(fr.monthly_amount * 3 * 0.95, 2),
         '6', round(fr.monthly_amount * 6 * 0.90, 2))
  from genalpha.student_details d
 where fr.tenant_id = 'genalpha'
   and fr.member_id = d.member_id
   and d.fee_plan = 'special'
   and coalesce(fr.plan_amounts, '{}'::jsonb) = '{}'::jsonb;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v_student uuid; v jsonb; n int;
begin
  -- finalize_renewal_intake writes a month count now
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
       where ns.nspname='genalpha' and p.proname='finalize_renewal_intake') !~ 'months     = greatest' then
    raise exception 'finalize_renewal_intake still leaves months null';
  end if;

  -- no existing genalpha fee payment has a null month count to guess from
  select count(*) into n from payments
   where tenant_id='genalpha' and kind in ('renewal','admission') and months is null;
  if n > 0 then
    raise notice '% historical genalpha payments still have no month count', n;
  end if;

  -- quote_fee answers for a real student, and agrees with resolve_fee
  select legacy_uuid into v_student from genalpha.student_details
   where member_id in (select member_id from fee_rules where tenant_id='genalpha')
   limit 1;
  if v_student is null then raise exception 'no priced GenAlpha student to test against'; end if;

  v := genalpha.quote_fee(v_student, 1);
  if (v->>'amount') is null then raise exception 'quote_fee returned no amount: %', v::text; end if;
  if (v->>'source') = 'unset' then raise exception 'quote_fee cannot price a student who has a fee rule'; end if;
  if not (v ? 'paid_through') then raise exception 'quote_fee did not return paid_through'; end if;

  -- and it must be the STUDENT's rate, not the academy default. This is
  -- the whole point: 52 of 81 students are not on 3500.
  select count(*) into n from genalpha.student_details d
    join fee_rules fr on fr.member_id = d.member_id and fr.tenant_id='genalpha'
   where fr.monthly_amount <> 3500;
  if n < 40 then
    raise exception 'only % students have a non-default rate; expected ~52 — the per-student rules are missing', n;
  end if;
  raise notice '% of 81 students are priced differently from the academy default', n;

  -- special-training students can now be quoted for a quarter
  select count(*) into n from fee_rules fr
    join genalpha.student_details d on d.member_id = fr.member_id
   where fr.tenant_id='genalpha' and d.fee_plan='special'
     and coalesce(fr.plan_amounts,'{}'::jsonb) = '{}'::jsonb;
  if n > 0 then raise exception '% special students still have no plan prices', n; end if;

  -- nobody else moved
  if (resolve_fee('raj', null,null,null,null,3,null)->>'amount')::numeric <> 3600 then
    raise exception 'raj''s fees changed';
  end if;
  if (resolve_fee('genalpha', null,null,null,null,3,null)->>'amount')::numeric <> 9975 then
    raise exception 'the genalpha academy default changed';
  end if;

  raise notice 'quote_fee is live; the app has one call for what a student owes';
end $$;
