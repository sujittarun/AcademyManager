/* THE PAY SHEET OPENS ON WHAT THE FAMILY PAYS
   ==================================================================
   scope: shared     affects: enrollment_fee(), reminder_queue()
                     behaviour changes for mezzo only (opt-in)

   WHY
   ---
   Mezzo has thirteen cancelled payments and every one of them is the
   operator correcting the app. Seven were the amount: he recorded the
   1,500 the sheet pre-filled, then corrected it to the 2,500 or 1,250
   the family actually pays. Two were fixed within fifteen seconds of
   being saved.

   2026-09-01a taught reminder_queue() to quote what a family last
   actually paid. It did not reach the PAY SHEET, which prices itself
   through enrollment_fee() — so the reminder asked for 2,500 and the
   sheet still opened on 1,500, and he corrected it by hand every time.
   One number, two functions, and only one of them had been told.

   WHAT CHANGES
   ------------
   1. enrollment_fee() honours the same opt-in key, with the same
      renewal-only rule, so the sheet opens on the same figure the
      reminder quotes.

   2. BOTH functions now multiply that monthly rate by the plan. This
      is a latent fault in 2026-09-01a: it quoted a MONTHLY rate against
      an enrolment whose plan might be three months, which would have
      under-asked by two thirds. Every Mezzo enrolment is on a one-month
      plan today — all seventy-four — so nothing has been mis-quoted;
      Raj has twenty-five on three months and eleven on twelve, and is
      not opted in, which is the only reason this never bit.

   BLAST RADIUS
   ------------
   enrollment_fee() is called by Mezzo's app, Raj's app, and Raj's iOS
   and Android clients, which cannot be force-updated. The signature and
   the shape of the answer are unchanged; the VALUE changes only for a
   tenant carrying config.reminders.amountFrom = 'lastPaid', which is
   mezzo alone. Raj's four clients cannot move.
   ================================================================== */

CREATE OR REPLACE FUNCTION public.reminder_queue(p_tenant text, p_on date DEFAULT NULL::date)
 RETURNS TABLE(enrollment_id bigint, member_id bigint, member_name text, parent_name text, phone text, centre text, batch text, sport text, due_date date, days_since integer, stage text, amount numeric, months integer, fee_source text, whatsapp_status text, blocked_reason text, already_sent boolean, last_sent_at timestamp with time zone, last_sent_status text, last_sent_channel text, upi_id text, upi_name text, upi_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cfg as (
    /* A tenant's chase RULE is tenant behaviour, so it lives in
       tenants.config and is read here — never reimplemented in a client,
       where the operator's screen and his WhatsApp message could then
       disagree about who is late. Absent config means the default
       ladder, so every existing tenant is untouched by this. */
    select coalesce(t.config->'reminders'->>'mode', 'ladder')      as mode,
           coalesce((t.config->'reminders'->>'afterDays')::int, 1) as after_days,
           coalesce(t.config->'reminders'->>'amountFrom', 'fee')  as amount_from
      from tenants t where t.id = p_tenant
  ),
  today as (select coalesce(p_on, ist_today()) as d),
  base as (
    select e.id as enrollment_id, e.member_id, m.name as member_name,
           m.parent_name,
           coalesce(nullif(m.parent_phone,''), nullif(m.phone,'')) as phone,
           c.short_name as centre, b.name as batch, e.sport,
           e.renewal_on as due_date,
           ((select d from today) - e.renewal_on) as days_since,
           e.plan_months as months,
           m.whatsapp_status,
           resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport, e.batch_id,
                       e.plan_months, e.custom_amount) as fee,
           resolve_upi(e.tenant_id, e.centre_id, e.batch_id) as upi
      from enrollments e
      join members m on m.id = e.member_id
      join centres c on c.id = e.centre_id
      left join batches b on b.id = e.batch_id
     where e.tenant_id = p_tenant
       and e.status = 'active'
       and m.status <> 'discontinued'
       and e.renewal_on is not null
  ),
  last_paid as (
    /* WHAT THIS FAMILY ACTUALLY PAYS, per month.

       resolve_fee() answers what the instrument COSTS. At Mezzo eleven
       of the sixty who have ever paid do not pay that: two are on a
       discount and nine pay more than the list price — up to double —
       because a lesson is priced per family, not per keyboard. Asking
       Aarik for the list 1,500 when the standing arrangement is 3,000
       is not a rounding error, it is the wrong number in a message to a
       parent.

       Divided by the months it covered, so a term paid up front gives a
       MONTHLY rate rather than the lump. Voided payments are not money.
       Payments with no enrolment are the "someone else paid" path and
       belong to nobody in particular. */
    select distinct on (p.enrollment_id)
           p.enrollment_id,
           round(p.amount / nullif(p.months, 0), 2) as monthly
      from payments p
     where p.tenant_id = p_tenant
       and p.kind = 'renewal'
       and p.status <> 'void'
       and p.enrollment_id is not null
       and p.amount is not null
       and coalesce(p.months, 0) > 0
     order by p.enrollment_id, p.on_date desc, p.id desc
  ),
  last_sent as (
    select distinct on (r.enrollment_id)
           r.enrollment_id, r.created_at, r.status, r.channel
      from reminder_events r
     where r.tenant_id = p_tenant and r.status <> 'void'
     order by r.enrollment_id, r.created_at desc
  )
  select
    base.enrollment_id, base.member_id, base.member_name, base.parent_name,
    base.phone, base.centre, base.batch, base.sport, base.due_date, base.days_since,
    case
      when (select mode from cfg) = 'simple' then 'overdue'
      when base.days_since = -2 then 'heads_up'
      when base.days_since = 0  then 'due'
      else 'overdue'
    end as stage,
    case when (select amount_from from cfg) = 'lastPaid' and lp.monthly is not null
         then lp.monthly * coalesce(base.months, 1)
         else (base.fee->>'amount')::numeric
    end as amount,
    base.months,
    case when (select amount_from from cfg) = 'lastPaid' and lp.monthly is not null
         then 'last_paid'
         else base.fee->>'source'
    end as fee_source,
    base.whatsapp_status,
    case
      when base.phone is null or length(regexp_replace(base.phone,'\D','','g')) < 10
        then 'missing_phone'
      when base.whatsapp_status = 'wrong_number' then 'wrong_phone_number'
      when base.whatsapp_status = 'opted_out'    then 'whatsapp_opted_out'
      when base.days_since >= 15
       and (select mode from cfg) <> 'simple'    then 'overdue_15_days'
      when coalesce(
             case when (select amount_from from cfg) = 'lastPaid'
                  then lp.monthly * coalesce(base.months, 1) end,
             (base.fee->>'amount')::numeric
           ) is null                               then 'fee_not_set'
      else null
    end as blocked_reason,
    exists (
      select 1 from reminder_events r
       where r.tenant_id = p_tenant
         and r.enrollment_id = base.enrollment_id
         and r.ist_date = (select d from today)
         and r.status <> 'void'
    ) as already_sent,
    ls.created_at as last_sent_at,
    ls.status     as last_sent_status,
    ls.channel    as last_sent_channel,
    base.upi->>'vpa'    as upi_id,
    base.upi->>'name'   as upi_name,
    base.upi->>'source' as upi_source
  from base
  left join last_paid lp on lp.enrollment_id = base.enrollment_id
  left join last_sent ls on ls.enrollment_id = base.enrollment_id
  where case
          -- Simple mode: one rule — "late by N days or more", every day
          -- until it is paid. No rungs to learn and none to explain.
          when (select mode from cfg) = 'simple'
            then base.days_since >= (select after_days from cfg)
          -- The default ladder, untouched for every tenant that has not
          -- opted out: -2 heads-up, 0 due, +5 first chase, +7..14 daily,
          -- +15 surfaced but blocked to manual.
          else base.days_since = -2
            or base.days_since = 0
            or base.days_since = 5
            or (base.days_since between 7 and 14)
            or base.days_since >= 15
        end
  order by base.days_since desc, base.member_name
$function$
;

CREATE OR REPLACE FUNCTION public.enrollment_fee(p_enrollment bigint, p_months integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e        enrollments;
  v_from   text;
  v_months int;
  v_rate   numeric;
begin
  select * into e from enrollments where id = p_enrollment;
  if not found then return jsonb_build_object('amount', null, 'source', 'missing'); end if;

  v_months := coalesce(p_months, e.plan_months, 1);

  select coalesce(t.config->'reminders'->>'amountFrom', 'fee')
    into v_from from tenants t where t.id = e.tenant_id;

  if v_from = 'lastPaid' then
    /* The monthly rate this family last actually paid, on a RENEWAL —
       an admission fee is a one-off and is not what they pay a month.
       Same rule, same divisor and same ordering as reminder_queue(), so
       the sheet and the reminder cannot quote different numbers. */
    select round(p.amount / nullif(p.months, 0), 2)
      into v_rate
      from payments p
     where p.tenant_id = e.tenant_id
       and p.enrollment_id = e.id
       and p.kind = 'renewal'
       and p.status <> 'void'
       and p.amount is not null
       and coalesce(p.months, 0) > 0
     order by p.on_date desc, p.id desc
     limit 1;

    if v_rate is not null then
      return jsonb_build_object('amount', v_rate * v_months, 'source', 'last_paid');
    end if;
  end if;

  return resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport, e.batch_id,
                     v_months, e.custom_amount);
end $function$;

do $$
declare
  v_sheet numeric; v_queue numeric; v_src text; v_enrol bigint;
begin
  /* the sheet and the reminder agree, for a family on a non-list rate */
  select e.id into v_enrol
    from enrollments e join members m on m.id = e.member_id
   where e.tenant_id='mezzo' and m.name = 'Aarik' and e.status='active';

  if v_enrol is not null then
    select (enrollment_fee(v_enrol)->>'amount')::numeric,
            enrollment_fee(v_enrol)->>'source'
      into v_sheet, v_src;
    if v_sheet <> 3000 then
      raise exception 'the pay sheet would open on % for Aarik, expected 3000', v_sheet;
    end if;
    if v_src <> 'last_paid' then
      raise exception 'Aarik''s 3000 is attributed to %, expected last_paid', v_src;
    end if;
    /* three months of it is three times it */
    if (enrollment_fee(v_enrol, 3)->>'amount')::numeric <> 9000 then
      raise exception 'three months is quoted as %, expected 9000',
        (enrollment_fee(v_enrol, 3)->>'amount');
    end if;
  end if;

  /* and nobody outside mezzo moved */
  if exists (
    select 1 from enrollments e
     where e.tenant_id <> 'mezzo' and e.status = 'active'
       and enrollment_fee(e.id)->>'source' = 'last_paid'
  ) then
    raise exception 'an enrolment outside mezzo is priced from a payment';
  end if;
end $$;
