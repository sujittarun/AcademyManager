-- ============================================================
-- 2026-08-31d · A month is a month, for every academy
-- scope: shared
--
-- "cycle shouldn't move to payment date" — the owner, 2026-08-31, after
-- watching karthikeya's billing anniversary move from the 21st to the 30th
-- because he paid ten days late.
--
-- The rule he is describing already exists. 2026-08-24b built it — "the cycle
-- is a chain, not a clock" — and record_fee_payment has carried it since,
-- reading tenants.config.fees.lateAnchor. But it defaulted to 'paid' and was
-- switched on for mezzo ONLY. Six academies, genalpha included, never got it.
--
-- This makes 'due' the default, so it is the platform's rule rather than one
-- tenant's setting. The config key remains for an academy that genuinely
-- wants to forgive a lapse; nothing sets it.
--
-- Everything the chain rule already handles is untouched and still holds:
-- paying early extends from the cycle end, a returning player's first fee
-- starts at the rejoin date, and the first fee ever recorded anchors the
-- cycle to its own payment date rather than to a join date typed in later.
--
-- Only the DEFAULT changes; the body is otherwise the live definition,
-- dumped with pg_get_functiondef and replayed so nothing is transcribed by
-- hand. Same signature, so CREATE OR REPLACE keeps the existing grants.
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_fee_payment(p_tenant text, p_enrollment bigint, p_amount numeric, p_months integer DEFAULT NULL::integer, p_mode text DEFAULT 'UPI'::text, p_kind text DEFAULT 'renewal'::text, p_on_date date DEFAULT NULL::date, p_ref text DEFAULT NULL::text, p_status text DEFAULT 'paid'::text, p_collected_by text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_period_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e       enrollments;
  m       members;
  months  int;
  paid_on date := coalesce(p_on_date, ist_today());
  from_d  date;
  to_d    date;
  pay_id  bigint;
  covers  boolean;
  v_rule  text;
  v_rejoin date;
begin
  perform assert_staff_or_service(p_tenant);

  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment has to be more than zero.' using errcode = 'check_violation';
  end if;
  if p_status not in ('paid', 'pending_verification') then
    raise exception 'Unknown payment status "%".', p_status using errcode = 'check_violation';
  end if;
  if p_kind not in ('renewal', 'admission', 'custom') then
    raise exception 'Unknown payment type "%".', p_kind using errcode = 'check_violation';
  end if;
  if p_months is not null and p_months not in (1, 3, 6, 12) then
    raise exception 'A plan is 1, 3, 6 or 12 months, not %.', p_months using errcode = 'check_violation';
  end if;

  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then
    raise exception 'That enrollment does not belong to this academy.' using errcode = 'no_data_found';
  end if;
  select * into m from members where id = e.member_id;

  -- WHICH CLOCK ANCHORS THE CYCLE, per tenant. Absent means 'paid', which is
  -- every tenant on the platform today and is byte-for-byte the old rule.
  -- 'due' is the chain rule: the next period starts where the last one ended,
  -- whatever day the money arrives. Same shape as config.reminders (2026-08-19r).
  -- 'due' IS THE RULE, not an opt-in. It was built on 2026-08-24 and switched
  -- on for mezzo alone, so every other academy kept billing from the payment
  -- date — and karthikeya, due on the 21st and paying on the 31st, had his
  -- anniversary moved to the 30th. A player a week late every month drifts a
  -- week later every month until they pay eleven months a year.
  --
  -- The config key stays as an escape hatch for an academy that genuinely
  -- wants to forgive lapses, but nothing sets it today.
  select coalesce(t.config->'fees'->>'lateAnchor', 'due') into v_rule
    from tenants t where t.id = p_tenant;
  v_rejoin := m.rejoined_at;

  -- A payment taken while the student is on a break has nothing to anchor to:
  -- the cycle is meant to restart on the day they come back, and that day is
  -- not known yet. Gated on the rule so the six tenants that have not opted in
  -- keep behaving exactly as before -- raj has four paused enrolments.
  if v_rule = 'due' and e.status = 'paused' then
    raise exception '% is on a break. Mark them back first, so the cycle starts the day they returned.', m.name
      using errcode = 'check_violation';
  end if;

  -- A joining fee on its own covers no time, so months defaults to
  -- zero there. Everything else defaults to the enrollment's own plan.
  months := coalesce(p_months, case when p_kind = 'admission' then 0 else e.plan_months end, 1);
  covers := months > 0;

  -- THE MONTHS BUY THE COVERAGE, NOT THE LABEL. This is the line the
  -- reported bug turned on: it used to read `if p_kind = 'renewal'`, so
  -- a joining fee covering three months bought the student nothing.
  if covers then
    -- Extend from the later of (current renewal, today): paying early
    -- never loses days, paying late never back-dates coverage over a
    -- period the student already sat through unpaid.
    --
    -- p_period_from overrides that, and ONLY the caller knows when it should.
    -- The case it exists for is a player returning from a break: they resume
    -- training on the rejoin date and settle a few days later, and those days
    -- are not a period "sat through unpaid" — they are the start of the cycle
    -- being bought. Default null, so every caller that does not pass it keeps
    -- the rule above exactly.
    from_d := coalesce(
      p_period_from,
      case when v_rule = 'due' then
        -- THE CYCLE IS A CHAIN, NOT A CLOCK. It continues from where the last
        -- period ended no matter when the money arrives: late does not buy the
        -- lapse, early does not lose it.
        --
        -- Unless they came back from a break. members.rejoined_at is the day
        -- they returned, and the days before it are days nobody taught them.
        -- The NOT EXISTS makes that apply to the FIRST fee after the return
        -- only; once it lands its period_from sits at or after the rejoin and
        -- every later renewal falls back to the chain. This is exactly the rule
        -- genalpha.student_payments_write has run since 2026-08-21c, lifted here
        -- so there is one implementation instead of two.
        greatest(
          case
            -- THE FIRST FEE DECIDES WHERE THE CYCLE BEGINS.
            -- Until money has arrived there is no cycle to chain from, and
            -- joined_on is the day he typed them into the app -- which for a
            -- student who has been coming for months is not when their cycle
            -- starts. So the first fee's own date is the anchor: record a fee
            -- dated the 20th for a student entered on the 24th and the cycle
            -- runs from the 20th. "Take the payment day as the joining day."
            -- Two conditions, and both are needed. No coverage fee has been
            -- taken (so there is nothing to chain from), AND the anchor has
            -- never moved off the joining day (so nothing else -- a resume, or
            -- a cycle that predates the app -- has already set where it runs
            -- from). Either one alone gets it wrong: an enrolment carrying a
            -- real cycle but no payment row yet would be re-anchored to the
            -- payment date, which is the lapse-gifting bug all over again.
            when not exists (select 1 from payments prior
                              where prior.enrollment_id = e.id
                                and prior.status <> 'void'
                                and prior.kind <> 'custom'
                                and coalesce(prior.months, 0) > 0)
                 and (e.renewal_on is null or e.renewal_on <= e.joined_on)
              then paid_on
            else coalesce(e.renewal_on, e.joined_on, paid_on)
          end,
          case when v_rejoin is not null
                 and not exists (select 1 from payments prior
                                  where prior.enrollment_id = e.id
                                    and prior.status <> 'void'
                                    and prior.kind <> 'custom'
                                    and prior.period_from >= v_rejoin)
               then v_rejoin end)
      else
        greatest(coalesce(e.renewal_on, paid_on), paid_on)
      end);

    -- A supplied start may not reach back over coverage already sold, and may
    -- not be in the future: either would let a caller mint or destroy months.
    if p_period_from is not null then
      if exists (select 1 from payments prior
                  where prior.enrollment_id = e.id and prior.status <> 'void'
                    and prior.kind <> 'custom' and prior.period_to > p_period_from) then
        raise exception 'That cycle start overlaps coverage this player has already paid for.'
          using errcode = 'check_violation';
      end if;
      if p_period_from > paid_on then
        raise exception 'A cycle cannot start after the payment that buys it.'
          using errcode = 'check_violation';
      end if;
    end if;
    to_d   := (from_d + (months || ' months')::interval)::date;
  else
    from_d := paid_on;
    to_d   := paid_on;
  end if;

  insert into payments (tenant_id, name, type, detail, amount, mode, on_date, ref,
                        enrollment_id, member_id, centre_id, sport, months,
                        period_from, period_to, kind, status, collected_by, note)
  values (p_tenant, m.name, 'Coaching',
          coalesce(e.sport, '') || case when covers and months > 1
                                        then ' · ' || months || ' months' else '' end,
          round(p_amount)::int, p_mode, paid_on, p_ref,
          e.id, e.member_id, e.centre_id, e.sport,
          case when covers then months else null end,
          from_d, to_d, p_kind, p_status, p_collected_by, p_note)
  returning id into pay_id;

  if p_status = 'paid' then
    perform apply_payment_coverage(p_tenant, pay_id);
  end if;

  -- The timeline stores the NUMBER, never a rendered string, so the web
  -- app and the Android app each format money exactly once.
  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id,
          case when p_status = 'paid' then 'payment' else 'payment_pending' end,
          case when p_status = 'paid' then 'Payment received'
               else 'Payment claimed, not verified yet' end,
          nullif(coalesce(p_note, ''), ''),
          jsonb_build_object(
            'payment_id', pay_id, 'amount', round(p_amount),
            'months', case when covers then months else null end,
            'kind', p_kind, 'mode', p_mode,
            'period_from', from_d, 'period_to', to_d, 'ref', p_ref,
            -- who took the payment. Without it the timeline says "System"
            -- for every payment any tenant has ever recorded.
            'changed_by', nullif(coalesce(p_collected_by, ''), '')));

  return jsonb_build_object(
    'payment_id', pay_id,
    'renewal_on', (select renewal_on from enrollments where id = e.id),
    'months', case when covers then months else 0 end,
    'period_from', from_d, 'period_to', to_d);
end $function$
;


-- ------------------------------------------------------------
-- karthikeya, recorded tonight under the old default. His enrolment read
-- renewal_on = 2026-08-21 at the moment of payment (confirmed against the
-- reminders that were still chasing that date), so the month he bought runs
-- 21 Aug - 21 Sep and his anniversary returns to the 21st.
-- ------------------------------------------------------------
do $$
declare v_pay bigint; v_enroll bigint; v_from date;
begin
  select p.id, e.id, p.period_from into v_pay, v_enroll, v_from
    from members m join enrollments e on e.member_id = m.id
    join payments p on p.enrollment_id = e.id
   where m.tenant_id = 'genalpha' and m.name = 'karthikeya'
     and p.status <> 'void' and p.on_date = date '2026-08-31';
  if v_pay is null then raise exception 'karthikeya has no payment dated 2026-08-31'; end if;
  if v_from <> date '2026-08-31' then
    raise exception 'karthikeya cycle already starts %, not the pay date — not re-correcting', v_from;
  end if;

  update payments set period_from = date '2026-08-21', period_to = date '2026-09-21'
   where id = v_pay;
  update enrollments set renewal_on = date '2026-09-21', updated_at = now()
   where id = v_enroll;
end $$;

do $$
declare v_default text; v_due date; v_acl text;
begin
  -- The default must now be 'due' for a tenant that sets nothing.
  select coalesce(config->'fees'->>'lateAnchor','(unset)') into v_default
    from tenants where id = 'genalpha';
  if v_default <> '(unset)' then
    raise exception 'genalpha now sets lateAnchor explicitly (%); this migration assumed the default', v_default;
  end if;
  if position($q$coalesce(t.config->'fees'->>'lateAnchor', 'due')$q$ in
      (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'record_fee_payment')) = 0 then
    raise exception 'record_fee_payment still defaults to paid';
  end if;

  select e.renewal_on into v_due
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.name = 'karthikeya';
  if v_due <> date '2026-09-21' then
    raise exception 'karthikeya next fee due is %, expected 2026-09-21', v_due;
  end if;

  select p.proacl::text into v_acl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_fee_payment';
  if v_acl is null or v_acl not like '%authenticated=X%' then
    raise exception 'authenticated lost execute on the money function: %', coalesce(v_acl,'(default)');
  end if;

  raise notice 'a month is a month for every academy; karthikeya is back on the 21st';
end $$;
