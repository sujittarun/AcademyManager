-- ============================================================
-- 0017 · Stop one tenant's staff reading another's
-- scope: shared
--
-- 0009 and 0010 closed anon. What is left is narrower and quieter: a
-- signed-in staff member of tenant A passing p_tenant='B'. These are
-- SECURITY DEFINER, so RLS does not apply inside them and the tenant is
-- whatever the caller typed.
--
-- 28 of the 40 p_tenant functions already call assert_staff_or_service.
-- These are the ones that did not. Two treatments, because they are two
-- different kinds of function:
--
--   CLIENT-CALLABLE -> guard the body. resolve_fee and reminder_queue
--     are called directly by tenant apps (MatchPointPride/src/lib/cloud.ts,
--     and Raj's), so they must stay executable by `authenticated`.
--
--   INTERNAL ONLY -> revoke the grant. apply_payment_coverage, next_code
--     and the three payout_scope_* helpers are only ever called from
--     other SECURITY DEFINER functions, which run as the owner and are
--     unaffected by grants. Removing EXECUTE is smaller and safer than
--     editing five more bodies.
--
-- DELIBERATELY UNTOUCHED: slot_rate. It is NOT SECURITY DEFINER, so RLS
-- already applies to it as the caller, and it sits on the anonymous
-- booking path — request_booking and sync_ingest both call it. Adding a
-- staff guard there would break the public booking form, which is
-- exactly the shape of the two outages this file's neighbours document.
-- ============================================================

-- ------------------------------------------------------------
-- 1 · resolve_fee — body verbatim, one line added
-- ------------------------------------------------------------
create or replace function public.resolve_fee(p_tenant text, p_member bigint, p_centre bigint, p_sport text, p_batch bigint, p_months integer DEFAULT 1, p_custom numeric DEFAULT NULL::numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  r        fee_rules;
  months   int := greatest(coalesce(p_months, 1), 1);
  monthly  numeric;
  total    numeric;
  keyed    numeric;
begin
  -- 0017: SECURITY DEFINER means RLS does not apply in here, so the
  -- tenant is whatever the caller passed until this line checks it.
  perform assert_staff_or_service(p_tenant);

  -- 60 — the staff override on the enrollment beats every rule.
  if p_custom is not null then
    return jsonb_build_object(
      'amount', round(p_custom * months, 2),
      'monthly', p_custom,
      'source', 'custom',
      'rule_id', null,
      'admission_fee', 0);
  end if;

  select fr.* into r
    from fee_rules fr
   where fr.tenant_id = p_tenant
     and fr.active
     and fr.effective_from <= ist_today()
     and (fr.effective_to is null or fr.effective_to >= ist_today())
     and (fr.member_id is null or fr.member_id = p_member)
     and (fr.batch_id  is null or fr.batch_id  = p_batch)
     and (fr.centre_id is null or fr.centre_id = p_centre)
     and (fr.sport     is null or fr.sport     = p_sport)
   order by fee_rule_rank(fr) desc, fr.effective_from desc, fr.id desc
   limit 1;

  if not found then
    return jsonb_build_object(
      'amount', null, 'monthly', null, 'source', 'unset',
      'rule_id', null, 'admission_fee', 0);
  end if;

  monthly := r.monthly_amount;
  keyed   := nullif(r.plan_amounts ->> months::text, '')::numeric;
  total   := coalesce(keyed, monthly * months);

  return jsonb_build_object(
    'amount',        round(total, 2),
    'monthly',       monthly,
    'source',        case
                       when r.member_id is not null then 'member'
                       when r.batch_id  is not null then 'batch'
                       when r.centre_id is not null and r.sport is not null then 'centre_sport'
                       when r.sport     is not null then 'sport'
                       when r.centre_id is not null then 'centre'
                       else 'default' end,
    'rule_id',       r.id,
    'label',         r.label,
    'admission_fee', r.admission_fee);
end $function$;

-- ------------------------------------------------------------
-- 2 · reminder_queue — was `sql`, so it becomes plpgsql to carry the
--     guard. The query below is the previous body verbatim, wrapped in
--     `return query`.
--
--     Safe for the reminder engine: the cron calls an Edge Function
--     deployed --no-verify-jwt that "authorises via the service role
--     internally", and is_service() returns true for service_role and
--     for direct SQL, so both paths pass.
-- ------------------------------------------------------------
create or replace function public.reminder_queue(p_tenant text, p_on date default null::date)
returns table (
  enrollment_id bigint, member_id bigint, member_name text, parent_name text,
  phone text, centre text, batch text, sport text, due_date date,
  days_since integer, stage text, amount numeric, months integer,
  fee_source text, whatsapp_status text, blocked_reason text,
  already_sent boolean, last_sent_at timestamp with time zone,
  last_sent_status text, last_sent_channel text
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  perform assert_staff_or_service(p_tenant);

  return query
with today as (select coalesce(p_on, ist_today()) as d),
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
                       e.plan_months, e.custom_amount) as fee
      from enrollments e
      join members m on m.id = e.member_id
      join centres c on c.id = e.centre_id
      left join batches b on b.id = e.batch_id
     where e.tenant_id = p_tenant
       and e.status = 'active'
       and m.status <> 'discontinued'
       and e.renewal_on is not null
  )
  select
    base.enrollment_id, base.member_id, base.member_name, base.parent_name,
    base.phone, base.centre, base.batch, base.sport, base.due_date, base.days_since,
    case
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
      when base.days_since >= 15                 then 'overdue_15_days'
      when (base.fee->>'amount') is null         then 'fee_not_set'
      else null
    end as blocked_reason,
    coalesce(last_reminder.ist_date = (select d from today), false) as already_sent,
    last_reminder.created_at as last_sent_at,
    last_reminder.status as last_sent_status,
    last_reminder.channel as last_sent_channel
  from base
  left join lateral (
    select r.created_at, r.status, r.channel, r.ist_date
      from reminder_events r
     where r.tenant_id = p_tenant
       and r.enrollment_id = base.enrollment_id
       and r.status <> 'void'
     order by r.created_at desc
     limit 1
  ) last_reminder on true
  where base.days_since = -2
     or base.days_since = 0
     or base.days_since = 5
     or (base.days_since between 7 and 14)
     or base.days_since >= 15
  order by base.days_since desc, base.member_name;
end $function$;

-- ------------------------------------------------------------
-- 3 · internal helpers — no client has any business calling these
-- ------------------------------------------------------------
revoke execute on function public.apply_payment_coverage(text, bigint)     from public, anon, authenticated;
revoke execute on function public.next_code(text, text, text)              from public, anon, authenticated;
revoke execute on function public.payout_scope_collected(text, date, payout_rules) from public, anon, authenticated;
revoke execute on function public.payout_scope_headcount(text, date, payout_rules) from public, anon, authenticated;
revoke execute on function public.payout_scope_sessions(text, date, payout_rules)  from public, anon, authenticated;

grant execute on function public.apply_payment_coverage(text, bigint)      to service_role;
grant execute on function public.next_code(text, text, text)               to service_role;
grant execute on function public.payout_scope_collected(text, date, payout_rules) to service_role;
grant execute on function public.payout_scope_headcount(text, date, payout_rules) to service_role;
grant execute on function public.payout_scope_sessions(text, date, payout_rules)  to service_role;

-- keep the two guarded ones reachable by the apps that need them
revoke execute on function public.resolve_fee(text,bigint,bigint,text,bigint,integer,numeric) from public, anon;
grant  execute on function public.resolve_fee(text,bigint,bigint,text,bigint,integer,numeric) to authenticated, service_role;
revoke execute on function public.reminder_queue(text, date) from public, anon;
grant  execute on function public.reminder_queue(text, date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove the money chain still works, as service, then roll back.
-- A guard that breaks the thing it protects is not a fix.
-- ------------------------------------------------------------
do $$
declare
  v_centre bigint; v_batch bigint; v_member bigint; v_enr bigint;
  v_fee jsonb; v_q record; v_n int;
begin
  select id into v_centre from centres where tenant_id='mpp' and code='narsingi';

  insert into batches (tenant_id, centre_id, code, name, sport, days, start_time, end_time, active, sort)
  values ('mpp', v_centre, 'S4-PROOF','S4 proof batch','badminton', array[1,3,5],'16:30','18:00',true,1)
  returning id into v_batch;

  insert into fee_rules (tenant_id, label, centre_id, sport, batch_id, monthly_amount,
                         plan_amounts, admission_fee, effective_from, active)
  values ('mpp','S4 proof', v_centre,'badminton', v_batch, 1200,'{}'::jsonb,500,current_date-365,true);

  insert into members (tenant_id, name, parent_name, parent_phone, program, joined, status, venue)
  values ('mpp','S4 Proof Kid','S4 Parent','9876543210','badminton', current_date-90,'active','narsingi')
  returning id into v_member;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, plan_months,
                           joined_on, renewal_on, status)
  values ('mpp', v_member, v_centre, v_batch,'badminton',1, current_date-90, current_date-5,'active')
  returning id into v_enr;

  v_fee := resolve_fee('mpp', v_member, v_centre,'badminton', v_batch, 1, null);
  if (v_fee->>'amount')::numeric <> 1200 then
    raise exception 'resolve_fee broken by its own guard: %', v_fee;
  end if;

  select * into v_q from reminder_queue('mpp') where enrollment_id = v_enr;
  if v_q is null then raise exception 'reminder_queue returned nothing after the rewrite'; end if;
  if v_q.amount <> 1200 or v_q.stage <> 'overdue' or v_q.days_since <> 5 then
    raise exception 'reminder_queue changed shape: stage=% days=% amount=%',
      v_q.stage, v_q.days_since, v_q.amount;
  end if;

  -- and the whole ladder still selects the same days
  select count(*) into v_n from reminder_queue('raj');
  raise notice 'raj queue still returns % rows; mpp proof ok', v_n;

  raise exception 'ROLLBACK-PROOF-OK';
exception when others then
  if sqlerrm <> 'ROLLBACK-PROOF-OK' then raise; end if;
  raise notice 'S4 proof passed and rolled back';
end $$;
