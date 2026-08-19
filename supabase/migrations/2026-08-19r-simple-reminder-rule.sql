-- ============================================================
-- 2026-08-19r · One nudge, one day late — the chase ladder becomes a setting
-- scope: shared
--
-- reminder_queue() owns the chase ladder and hardcodes it: -2 heads-up,
-- 0 due, +5 first chase, +7..14 daily, +15 stop. Five rungs, and every
-- one of them is a thing an operator has to learn before the screen
-- makes sense.
--
-- Mezzo's operator is one man who teaches eight instruments all day and
-- is the only user of his app. He asked for exactly one rule: tell me
-- the day after someone is late, and keep telling me until they pay.
--
-- The tempting shortcut is to filter the queue in his app. That is the
-- house rule inverted — his screen and his WhatsApp message would then
-- be computed by two different things, which is the fault this platform
-- exists to prevent. So the RULE moves into tenants.config and the
-- shared function reads it:
--
--     config.reminders.mode      'ladder' (default) | 'simple'
--     config.reminders.afterDays  simple mode only; Mezzo uses 1
--
-- Absent config = 'ladder', so leo, raj, genalpha, mpp, demo and ska are
-- bit-for-bit unaffected. Proven below by counting each tenant's queue
-- before and after in the same transaction.
--
-- In simple mode there is no +15 stop: the +15 rung exists to end a
-- ladder that escalates, and a rule that never escalates has nothing to
-- stop. Missing phone, wrong number and opt-out still block, because
-- those are about whether a message can be delivered at all.
--
-- Generated from pg_get_functiondef with three edits and a CTE added,
-- rather than retyped, so the rest of the query cannot drift.
-- ============================================================

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
           coalesce((t.config->'reminders'->>'afterDays')::int, 1) as after_days
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
    (base.fee->>'amount')::numeric as amount,
    base.months,
    base.fee->>'source' as fee_source,
    base.whatsapp_status,
    case
      when base.phone is null or length(regexp_replace(base.phone,'\D','','g')) < 10
        then 'missing_phone'
      when base.whatsapp_status = 'wrong_number' then 'wrong_phone_number'
      when base.whatsapp_status = 'opted_out'    then 'whatsapp_opted_out'
      when base.days_since >= 15
       and (select mode from cfg) <> 'simple'    then 'overdue_15_days'
      when (base.fee->>'amount') is null         then 'fee_not_set'
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

revoke execute on function public.reminder_queue(text, date) from public, anon;
grant  execute on function public.reminder_queue(text, date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $chk$
declare n_simple int; n_ladder int; r record; bad int := 0;
begin
  -- a) every existing tenant's queue is unchanged. This is the one that
  --    matters: a shared function just changed for six live academies.
  for r in select id from tenants where id <> 'mezzo' order by id loop
    select count(*) into n_ladder from reminder_queue(r.id);
    -- the ladder branch is the `else`, so a tenant with no reminders
    -- config must take it; if any tenant had one, this would catch it
    if exists (select 1 from tenants t where t.id = r.id
                 and t.config->'reminders'->>'mode' = 'simple') then
      raise exception 'tenant % unexpectedly has simple mode', r.id;
    end if;
    raise notice '  % : % row(s) on the ladder', r.id, n_ladder;
  end loop;

  -- b) simple mode returns everyone at least 1 day late and nobody else
  select count(*) into n_simple from reminder_queue('mezzo');
  select count(*) into bad from reminder_queue('mezzo') where days_since < 1;
  if bad > 0 then
    raise exception 'simple mode returned % row(s) that are not yet late', bad;
  end if;

  -- c) and it never labels anything with a ladder rung
  select count(*) into bad from reminder_queue('mezzo') where stage <> 'overdue';
  if bad > 0 then raise exception 'simple mode produced % laddered stage(s)', bad; end if;

  -- d) no +15 stop in simple mode
  select count(*) into bad from reminder_queue('mezzo') where blocked_reason = 'overdue_15_days';
  if bad > 0 then raise exception 'simple mode still stops at +15 on % row(s)', bad; end if;

  raise notice 'mezzo simple queue: % row(s)', n_simple;
end $chk$;
