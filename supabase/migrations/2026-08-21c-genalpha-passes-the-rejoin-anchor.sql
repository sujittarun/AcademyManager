-- ============================================================
-- 2026-08-21c · GenAlpha tells the money function when a player came back
-- scope: shared
--
-- The other half of 2026-08-21b. student_payments_write already received the
-- intended cycle (new.cycle_start_date) and stored it in students.renewals;
-- now it passes the rejoin anchor to record_fee_payment so the money and the
-- tenant layer stop disagreeing.
--
-- Only the first fee after a return is anchored. Once it lands, its
-- period_from sits at or after the rejoin date, the guard below finds it, and
-- every later renewal falls back to the ordinary rule.
-- ============================================================

CREATE OR REPLACE FUNCTION genalpha.student_payments_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_member bigint; v_enroll bigint; v_months int; v_kind text; v_result jsonb; v_id bigint;
  v_rejoined date; v_anchor date;
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

  -- ONE PAYMENT PER CYCLE. Ayaan Bejugam had three renewals recorded in
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

  -- A PLAYER BACK FROM A BREAK PAYS FROM THE DAY THEY CAME BACK.
  -- Only for the FIRST fee after the return: once that one lands, its
  -- period_from is at or after the rejoin date, this finds it, and every later
  -- renewal goes back to the ordinary rule. Without that condition a rejoined
  -- player would be billed from their due date forever, which is a different
  -- policy than the one that was chosen.
  select m.rejoined_at into v_rejoined from members m where m.id = v_member;
  v_anchor := null;
  if v_rejoined is not null and v_kind <> 'custom' then
    if not exists (select 1 from payments prior
                    where prior.enrollment_id = v_enroll and prior.status <> 'void'
                      and prior.kind <> 'custom' and prior.period_from >= v_rejoined)
    then
      select greatest(v_rejoined, coalesce(e.renewal_on, v_rejoined)) into v_anchor
        from enrollments e where e.id = v_enroll;
      -- Nothing to override when the anchor is not actually earlier than the
      -- payment: record_fee_payment already lands on the same date.
      if v_anchor >= coalesce(new.paid_on, ist_today()) then v_anchor := null; end if;
    end if;
  end if;

  v_result := record_fee_payment(
    'genalpha', v_enroll, new.amount, v_months, coalesce(new.payment_method,'UPI'),
    v_kind, coalesce(new.paid_on, ist_today()), nullif(new.payment_reference,''),
    'paid', coalesce(new.recorded_by,'GenAlpha app'), new.comment, v_anchor);
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
end $function$
;


-- ------------------------------------------------------------
-- Dhruvan's own payment, recorded before this existed. He rejoined on the
-- 17th and paid on the 20th, so his month runs 17 Aug - 17 Sep. Guarded on
-- the exact shape so re-running cannot touch anything else.
-- ------------------------------------------------------------
with fix as (
  select p.id as payment_id, e.id as enrollment_id,
         m.rejoined_at as anchor,
         (m.rejoined_at + make_interval(months => p.months))::date as anchor_to,
         p.period_to as old_to
    from payments p
    join enrollments e on e.id = p.enrollment_id
    join members m on m.id = e.member_id
   where p.tenant_id = 'genalpha'
     and p.status <> 'void'
     and p.kind = 'renewal'
     and m.rejoined_at is not null
     and p.period_from > m.rejoined_at
     and p.on_date >= m.rejoined_at
     and not exists (
       select 1 from payments other
        where other.enrollment_id = p.enrollment_id and other.status <> 'void'
          and other.kind <> 'custom' and other.id <> p.id
          and other.period_from >= m.rejoined_at)
),
fixed_payments as (
  update payments p set period_from = f.anchor, period_to = f.anchor_to
    from fix f where p.id = f.payment_id
   returning p.id
)
update enrollments e set renewal_on = f.anchor_to
  from fix f where e.id = f.enrollment_id and e.renewal_on = f.old_to;

do $$
declare v_due date;
begin
  select e.renewal_on into v_due
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.name = 'Sriramineni Dhruvan';
  if v_due <> date '2026-09-17' then
    raise exception 'Dhruvan next fee due is %, expected 2026-09-17', v_due;
  end if;
  raise notice 'a returning player is billed from the day they came back';
end $$;
