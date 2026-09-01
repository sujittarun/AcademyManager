/* THE REMINDER QUOTES WHAT THE FAMILY ACTUALLY PAYS
   ==================================================================
   scope: shared        affects: reminder_queue(), opt-in per tenant

   WHY
   ---
   resolve_fee() answers what an instrument COSTS. It is the right
   answer for a new enrolment and the wrong one for a family that has
   been paying something else for months.

   At Mezzo, of the sixty enrolments that have ever paid, ELEVEN do not
   pay the list price — and only two of those are discounts:

       Anukarthika, Navanitha        1,250   (list 1,500)
       Ponraj                        2,000
       Bhagavathi Dev, Olivia,
       Vimal, Patricia, Reena,
       Suresh                        2,500
       Aarik, Hariharan              3,000

   Nine of the eleven pay MORE than the list, up to double it, because a
   music lesson is priced per family and not per keyboard. The reminder
   was quoting 1,500 to all of them. Asking Aarik for 1,500 when the
   standing arrangement is 3,000 is not a rounding error; it is the
   wrong number, in a message, to a parent.

   WHAT CHANGES
   ------------
   When a tenant sets config.reminders.amountFrom = 'lastPaid', the
   queue quotes the monthly rate from that enrolment's most recent
   non-void payment, dividing by the months it covered so a term paid up
   front yields a monthly figure. A family that has never paid falls
   back to resolve_fee() exactly as before, and fee_source says
   'last_paid' so the origin of the number stays visible.

   WHY IT IS HERE AND NOT IN THE APP
   ---------------------------------
   The house rule. The dues list, the family card, the amount seeded
   into the payment sheet and the text of the WhatsApp message all read
   this one column. Computing it in the client would let the operator's
   screen and his message disagree, which is the exact failure the
   "do not filter the dues list" comment in Mezzo's app.html exists to
   prevent.

   BLAST RADIUS
   ------------
   Opt-in. Every tenant without the key keeps 'fee' and is unchanged;
   only mezzo is switched on below. genalpha in particular sends
   automatically every day at 15:00 IST and must not move.
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
         then lp.monthly
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
             case when (select amount_from from cfg) = 'lastPaid' then lp.monthly end,
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

/* Mezzo asked for it; nobody else has. */
update tenants
   set config = jsonb_set(config, '{reminders,amountFrom}', '"lastPaid"'::jsonb, true)
 where id = 'mezzo';

do $$
declare
  v_mezzo   int;
  v_others  int;
  v_aarik   numeric;
begin
  /* the key landed, and on exactly one tenant */
  select count(*) into v_mezzo  from tenants
   where config->'reminders'->>'amountFrom' = 'lastPaid';
  if v_mezzo <> 1 then
    raise exception 'amountFrom is set on % tenants, expected exactly 1', v_mezzo;
  end if;

  /* every other tenant still resolves from the fee chain */
  select count(*) into v_others from tenants t
   where t.id <> 'mezzo'
     and coalesce(t.config->'reminders'->>'amountFrom', 'fee') <> 'fee';
  if v_others <> 0 then
    raise exception '% other tenants were switched on by accident', v_others;
  end if;

  /* and the number actually moved for the family it was written for */
  select q.amount into v_aarik
    from reminder_queue('mezzo') q
    join members m on m.id = q.member_id
   where m.name = 'Aarik';
  if v_aarik is not null and v_aarik <> 3000 then
    raise exception 'Aarik is still being quoted %, expected 3000', v_aarik;
  end if;
end $$;
