-- ============================================================
-- 2026-08-21b · A returning player's cycle starts when training resumed
-- scope: shared
--
-- "I marked Sriramineni Dhruvan rejoined from 17 Aug but payment done on the
-- 20th, so next fee due should be calculated from the 17th."
--
-- record_fee_payment computed greatest(renewal_on, paid_on), so it billed from
-- the 20th and the next fee fell on 20 Sep. That is the rule the function
-- documents and it is right for an ordinary late renewal: a player who lets a
-- cycle lapse and pays three weeks later is not charged for the lapse.
--
-- A rejoin is not that. The player resumed training on the 17th and trained
-- the 17th to the 20th; those days are the start of the cycle being bought,
-- not a period sat through unpaid. The tenant layer already knew this — the
-- app sends cycle_start_date and student_payments_write stores it in
-- students.renewals — but the money function was never told, so the two
-- disagreed: renewals said 2026-08-17 while the payment said 2026-08-20.
-- Two answers to "when did this cycle start" is the thing the house rule
-- exists to prevent.
--
-- So record_fee_payment gains an OPTIONAL p_period_from. Default null means
-- every existing caller — six other functions, six other tenants — behaves
-- byte-for-byte as before; only a caller that passes it opts in. Two guards
-- stop it being abused: it may not overlap coverage already paid for, and it
-- may not start after the payment that buys it.
--
-- Adding a defaulted argument creates a NEW signature rather than replacing
-- the old one, and two overloads would make every 11-argument call ambiguous,
-- so the old function is dropped first. A dropped function loses its grants;
-- they are restored and asserted below.
--
-- Chosen by the owner on 2026-08-21 over the wider option of billing every
-- late payment from its due date. That one closes a real leak — a chronic
-- late payer drifts their due date later every cycle — but it changes money
-- for all seven tenants and what parents are told, so it stays unmade.
-- ============================================================

drop function if exists public.record_fee_payment(text, bigint, numeric, integer, text, text, date, text, text, text, text);

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
    from_d := coalesce(p_period_from, greatest(coalesce(e.renewal_on, paid_on), paid_on));

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


revoke execute on function public.record_fee_payment(text, bigint, numeric, integer, text, text, date, text, text, text, text, date) from public, anon;
grant  execute on function public.record_fee_payment(text, bigint, numeric, integer, text, text, date, text, text, text, text, date) to authenticated, service_role;

do $$
declare v_count int; v_acl text;
begin
  select count(*) into v_count from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_fee_payment';
  if v_count <> 1 then
    raise exception '% record_fee_payment overloads exist; every call would be ambiguous', v_count;
  end if;

  select p.proacl::text into v_acl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_fee_payment';
  if v_acl is null or v_acl not like '%authenticated=X%' then
    raise exception 'authenticated lost execute on the money function: %', coalesce(v_acl,'(default)');
  end if;
  if has_function_privilege('anon', 'public.record_fee_payment(text, bigint, numeric, integer, text, text, date, text, text, text, text, date)', 'execute') then
    raise exception 'anon can execute record_fee_payment';
  end if;

  raise notice 'record_fee_payment accepts an optional cycle start; default behaviour unchanged';
end $$;
