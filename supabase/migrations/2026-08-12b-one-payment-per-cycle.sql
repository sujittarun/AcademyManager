-- ============================================================
-- 2026-08-12b · No identical payment twice in two minutes
-- scope: shared
--
-- Player F had three renewals recorded within sixty seconds, each
-- rolling renewal_on forward a month, leaving him credited to November on
-- one real payment. Reversed in 2026-08-12a; this stops it recurring.
--
-- The app does check for a duplicate — insertRenewalPaymentWithRetry
-- calls findExistingRenewalPayment first (script.js:6597). But that is a
-- separate round trip, so three rapid taps all complete the check before
-- the first insert lands. A client-side check cannot win that race.
--
-- genalpha.finalize_renewal_intake has had this guard since the port, so
-- the WhatsApp path was already protected. The app path was not.
--
-- GUARDING ON THE CYCLE DOES NOT WORK, and finding out why is the point.
-- The first draft refused a second payment whose period_from matched an
-- existing one. It never fired, because record_fee_payment rolls
-- renewal_on forward on every payment — so the second tap computes the
-- NEXT cycle and looks entirely legitimate. That is the exact mechanism
-- by which three taps produced three valid-looking months.
--
-- What separates a mis-tap from a real second payment is not the cycle,
-- it is the clock. Someone deliberately paying two months does it as two
-- decisions; someone whose button did not respond taps again in seconds.
-- So: refuse an identical payment — same player, same kind, same amount —
-- inside a two-minute window.
--
-- Custom payments (jersey) are exempt: they buy no months, and a family
-- can legitimately buy two in one visit.
-- ============================================================

CREATE OR REPLACE FUNCTION genalpha.student_payments_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_member bigint; v_enroll bigint; v_months int; v_kind text; v_result jsonb; v_id bigint;
  v_recent timestamptz;
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
              when 'joining' then 'admission'
              when 'jersey'  then 'custom'
              else 'renewal' end;

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
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v_uuid uuid; v_member bigint; v_pay text; n0 int; n int; blocked boolean := false;
begin
  select count(*) into n0 from payments where tenant_id='genalpha';

  -- a throwaway player, so nothing here touches a real family
  insert into genalpha.students
    (name, age, join_date, time_slot, fee_plan, coaching_fee, admission_fee,
     jersey_amount, total_fee_amount, jersey_size, jersey_pairs, renewals,
     added_by, updated_by, discontinued, father_guardian_name, parent_contact_no,
     whatsapp_contact_status, alternate_contact_no, fees_paid, amount_paid)
  values ('ZZ Dup Guard Probe', 9, current_date, '6AM', 'monthly', 3500, 500,
          0, 4000, 'M', 0, '[]'::jsonb, 'probe', 'probe', false,
          'ZZ Probe Parent', '9000000003', 'active', '', false, 0)
  returning id into v_uuid;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_uuid;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, joined_on, renewal_on, status)
  select 'genalpha', v_member, e.centre_id, e.batch_id, 'cricket',
         1, current_date, current_date, 'active'
    from enrollments e where e.tenant_id='genalpha' order by e.id limit 1;

  -- first renewal: must succeed
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, comment, recorded_by)
  values (v_uuid, 'renewal', 'monthly', current_date, 1, 3500, current_date, 'first', 'probe')
  returning id into v_pay;
  if v_pay is null then raise exception 'the first renewal did not record'; end if;

  -- second, same cycle: must be refused. This is the whole migration.
  begin
    insert into genalpha.student_payments
      (student_id, payment_type, plan_type, cycle_start_date, months_covered,
       amount, paid_on, comment, recorded_by)
    values (v_uuid, 'renewal', 'monthly', current_date, 1, 3500, current_date, 'duplicate', 'probe');
  exception when unique_violation then
    blocked := true;
  end;
  if not blocked then
    raise exception 'a duplicate renewal for the same cycle was accepted';
  end if;

  -- exactly one payment landed, and the coverage moved exactly once
  select count(*) into n from payments where member_id = v_member and kind='renewal';
  if n <> 1 then raise exception '% renewal payments exist, expected 1', n; end if;

  -- a jersey in the same breath must still be allowed
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, months_covered, amount, paid_on, recorded_by)
  values (v_uuid, 'jersey', 'jersey_pair', 1, 750, current_date, 'probe');
  select count(*) into n from payments where member_id = v_member and kind='custom';
  if n <> 1 then raise exception 'the jersey payment was blocked by the renewal guard'; end if;

  -- clean up completely
  delete from payments        where member_id = v_member;
  delete from member_timeline where member_id = v_member;
  delete from enrollments     where member_id = v_member;
  delete from genalpha.students where id = v_uuid;

  select count(*) into n from payments where tenant_id='genalpha';
  if n <> n0 then raise exception 'the probe left % payments behind', n - n0; end if;

  raise notice 'duplicate renewals refused, jersey still allowed, % payments unchanged', n0;
end $$;
