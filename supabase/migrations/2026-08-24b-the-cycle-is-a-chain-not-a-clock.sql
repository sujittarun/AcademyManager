-- ============================================================
-- 2026-08-24b · The cycle is a chain, not a clock
-- scope: shared
--
-- "when new payment is added, might be payment is done after overdue days,
--  so calculate from previous cycle day"
--
-- TWO CLOCKS, AND ONLY ONE OF THEM IS THE CYCLE.
--   payments.on_date  is when the money changed hands. It drives the ledger,
--                     the month totals and compute_payouts, and it has no
--                     opinion about coverage at all.
--   renewal_on        is the first day not yet paid for -- the anchor, and the
--                     only cycle state the platform keeps.
-- greatest(renewal_on, paid_on) let the first reach into the second: pay six
-- days late and the new period started on the payment date, quietly gifting
-- six days, and it compounds every cycle for a habitual late payer.
--
-- THIS IS A REVERSAL, AND IT IS OPT-IN. 2026-08-21b chose the narrow fix over
-- exactly this change, because it "changes money for all seven tenants and
-- what parents are told". That reasoning still holds for the other six, so the
-- rule is per-tenant: tenants.config.fees.lateAnchor, absent meaning 'paid',
-- which is the old behaviour byte for byte. Only mezzo is flipped, at the foot
-- of this file, the way 2026-08-19r flipped config.reminders.
--
-- NOT config.billing -- that object is the collection account resolve_upi()
-- reads (upiIds, payee). A cycle rule nested inside the UPI details would make
-- one key mean two unrelated things.
--
-- WHAT IT MEASURABLY CHANGES TODAY: nothing already stored. The old branch has
-- produced a second-cycle date three times in this platform's history, all
-- mezzo, all on 2026-08-24, all with period_from exactly equal to the prior
-- period_to -- zero drift. demo's 227 payments carry NULL period_from so the
-- rule never ran for one of them; raj has one payment per enrolment and has
-- never had a renewal; no genalpha enrolment has two coverage payments. Only
-- four functions in the database read period_from/period_to at all
-- (record_fee_payment, apply_payment_coverage, void_payment,
-- enrollment_payment_summary). No payout, ledger or month total reads the
-- cycle -- they all run on on_date.
--
-- A BREAK IS RECORDED, NOT INFERRED. Nothing inside a payment can tell "he
-- attended all along and paid six weeks late" from "he stopped coming for six
-- weeks". Any threshold is a cliff nobody can explain to a parent. So the
-- return date is a recorded fact -- members.rejoined_at, which genalpha has
-- populated since 2026-08-21c -- and the rule that reads it is lifted out of
-- genalpha.student_payments_write into here, so there is one implementation
-- rather than two. GenAlpha passes its own anchor as the 12th argument and
-- coalesce() keeps that winning, so its behaviour does not move.
--
-- THE PAUSED GUARD IS GATED on the same rule. Ungated it would make raj's four
-- paused enrolments start refusing payments from two mobile binaries that
-- cannot be force-updated.
--
-- add_student() IS FIXED IN THE SAME BREATH. It hardcoded
-- renewal_on = ist_today() + 1 month -- the identical free-first-period bug
-- Mezzo's client shed earlier today. Leaving it would have Postgres holding
-- two answers to "when does the first cycle start". Only ska calls it.
--
-- Reverting: this is a body-only CREATE OR REPLACE, so 2026-08-24e restores
-- the previous body. Note that unflipping the config un-bills nothing already
-- written -- period_from/period_to are frozen at insert and
-- apply_payment_coverage has already moved renewal_on. The only true undo of
-- an individual payment is void_payment, in strict reverse order.
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
  select coalesce(t.config->'fees'->>'lateAnchor', 'paid') into v_rule
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
          coalesce(e.renewal_on, e.joined_on, paid_on),
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
end $function$;
-- ------------------------------------------------------------
-- add_student(): the first cycle starts on the joining day
--
-- It honoured a backdated p_joined_on for joined_on and then ignored it for
-- renewal_on, always writing ist_today() + 1 month. Backdate a joining date by
-- three months and the student was billed from a month after data entry -- and
-- with no backdating at all they still got their first period free, which is
-- the bug Mezzo's client shed earlier today. reenroll_member has always used
-- coalesce(p_renewal_on, v_on); this now agrees with it.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_student(p_tenant text, p_name text, p_phone text DEFAULT NULL::text, p_batch bigint DEFAULT NULL::bigint, p_parent_name text DEFAULT NULL::text, p_dob date DEFAULT NULL::date, p_joined_on date DEFAULT NULL::date, p_centre bigint DEFAULT NULL::bigint, p_by text DEFAULT NULL::text, p_custom_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone   text;
  v_centre  bigint;
  v_joined  date;
  v_mid     bigint;
  v_eid     bigint;
  v_exist   bigint;
  v_chain   jsonb;
  v_fee     jsonb;
  v_custom  numeric;
  v_matched boolean := false;
begin
  perform assert_staff(p_tenant);

  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'A name is required.';
  end if;

  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  if v_phone is not null then
    if length(v_phone) < 10 then
      raise exception 'That mobile number is not 10 digits.';
    end if;
    v_phone := right(v_phone, 10);
  end if;

  /* Zero is a real answer — a scholarship — so only a NEGATIVE amount is
     nonsense. The client must send null, not 0, for "left blank": the two
     mean opposite things to the chain, blank deferring to the batch and
     zero overriding it. */
  v_custom := p_custom_amount;
  if v_custom is not null and v_custom < 0 then
    raise exception 'A fee cannot be negative.';
  end if;

  if v_phone is not null then
    select id into v_exist from members
     where tenant_id = p_tenant
       and lower(btrim(name)) = lower(btrim(p_name))
       and (phone = v_phone or parent_phone = v_phone)
       and status <> 'discontinued'
     limit 1;
  else
    select id into v_exist from members
     where tenant_id = p_tenant
       and lower(btrim(name)) = lower(btrim(p_name))
       and phone is null and parent_phone is null
       and status <> 'discontinued'
     limit 1;
  end if;
  if v_exist is not null then
    return jsonb_build_object('ok', false, 'duplicate', true,
                              'member_id', v_exist,
                              'message', p_name || ' is already on the roll.');
  end if;

  if p_centre is not null then
    select id into v_centre from centres
     where id = p_centre and tenant_id = p_tenant and active;
    if v_centre is null then
      raise exception 'That centre does not belong to this academy.';
    end if;
  else
    select id into v_centre from centres
     where tenant_id = p_tenant and active order by id limit 1;
    if v_centre is null then
      raise exception 'This academy has no active centre yet.';
    end if;
  end if;

  if p_batch is not null and not exists (
       select 1 from batches where id = p_batch and tenant_id = p_tenant) then
    raise exception 'That batch does not belong to this academy.';
  end if;

  v_joined := coalesce(p_joined_on, ist_today());
  if v_joined > ist_today() then
    raise exception 'A joining date cannot be in the future.';
  end if;

  insert into members (tenant_id, name, phone, parent_name, parent_phone,
                       dob, program, joined, status, added_by)
  values (p_tenant, btrim(p_name), v_phone,
          nullif(btrim(coalesce(p_parent_name, '')), ''), v_phone,
          p_dob, 'Cricket coaching', v_joined, 'active', p_by)
  returning id into v_mid;

  /* What the chain says on its own, asked with the SAME arguments the
     reminder ladder will use later — the enrolment stores no sport, so a
     sport passed here and not there would quote one number today and
     chase a different one next month. 19h passed 'cricket'; harmless while
     every rule has sport null, wrong the day one does not. */
  v_chain := resolve_fee(p_tenant, v_mid, v_centre, null, p_batch, 1, null);

  if v_custom is not null
     and (v_chain ->> 'monthly') is not null
     and (v_chain ->> 'monthly')::numeric = v_custom then
    v_custom  := null;
    v_matched := true;
  end if;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id,
                           plan_months, custom_amount, joined_on, renewal_on, status)
  values (p_tenant, v_mid, v_centre, p_batch,
          1, v_custom, v_joined, v_joined, 'active')
  returning id into v_eid;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, v_mid, v_eid, 'admission', 'Added to the roll',
          'Existing student entered by ' || coalesce(p_by, 'staff') ||
          case when v_custom is not null
               then ' · fee set for this student at ' || trim(to_char(v_custom, 'FM999999990.00'))
               else '' end);

  v_fee := case when v_custom is null then v_chain
                else resolve_fee(p_tenant, v_mid, v_centre, null, p_batch, 1, v_custom) end;

  return jsonb_build_object('ok', true, 'duplicate', false,
                            'member_id', v_mid, 'enrollment_id', v_eid,
                            'no_phone', (v_phone is null),
                            'custom', v_custom,
                            'matched_rule', v_matched,
                            'fee', v_fee);
end
$function$;
-- ------------------------------------------------------------
-- Mezzo opts in.
--
-- An OBJECT MERGE, never jsonb_set: mezzo's config has no `fees` key, and
-- jsonb_set with create_missing only creates the FINAL key -- which is how
-- 0004 took Raj's public timetable down with a silent no-op.
-- ------------------------------------------------------------
update tenants
   set config = config || jsonb_build_object(
                  'fees',
                  coalesce(config->'fees', '{}'::jsonb) || jsonb_build_object('lateAnchor', 'due'))
 where id = 'mezzo';

do $$
declare v text; n int;
begin
  select config->'fees'->>'lateAnchor' into v from tenants where id = 'mezzo';
  if v is distinct from 'due' then
    raise exception 'lateAnchor did not land for mezzo (got %) -- the merge was a no-op', v;
  end if;

  -- and nobody else moved
  select count(*) into n from tenants
   where id <> 'mezzo' and config->'fees'->>'lateAnchor' is not null;
  if n <> 0 then raise exception '% other tenant(s) picked up a lateAnchor', n; end if;

  -- the collection account must be untouched: it lives in config.billing and
  -- resolve_upi() reads it every time a fee is quoted
  select count(*) into n from tenants where id = 'mezzo' and config ? 'billing';
  raise notice 'mezzo billing key present: % (0 is fine, it had none)', n;

  raise notice 'mezzo now bills from the due date; the other six are unchanged';
end $$;
