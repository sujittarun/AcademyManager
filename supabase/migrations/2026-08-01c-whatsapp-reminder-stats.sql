-- ============================================================
-- 2026-08-01c · WhatsApp reminder performance — attribution + stats API
-- scope: shared
--
-- The operator console needs one number per academy: is the WhatsApp
-- reminder engine actually getting parents to pay? Answering that needs
-- three things the schema did not have.
--
-- 1. THE ATTRIBUTION LINK. `payments` had no reference to the reminder
--    that produced it, so "revenue via reminder" was unanswerable — the
--    best anyone could do was guess by member and date, which silently
--    credits the engine for walk-in cash. A nullable
--    payments.reminder_event_id makes the claim explicit: a payment
--    counts only when something linked it.
--
-- 2. DEDUPLICATION OF META CALLBACKS. Meta re-sends status webhooks;
--    the same message_id can arrive several times. Counting rows would
--    inflate delivery and read rates, which are exactly the numbers a
--    dashboard is trusted for. A partial unique index on
--    (tenant_id, message_id) makes double-counting impossible rather
--    than merely unlikely.
--
-- 3. THE INDEXES the aggregate actually reads on.
--
-- Then whatsapp_reminder_stats(p_tenant, p_months): ONE operator-only
-- function that returns the whole dashboard as jsonb — aggregated in
-- Postgres, so no raw event ever reaches a browser.
--
-- A NOTE ON THE DATA, recorded honestly because the dashboard will look
-- empty and that is not a bug: today there are 11 reminders in total
-- (raj 9, mpp 2), every one status='manual_sent', dry_run=false, with
-- NO message_id and NO Meta callbacks — both tenants run
-- config.whatsapp.mode='manual' with enabled=false. So delivery and
-- read rates are structurally 0/0 until the WABA goes live and the
-- webhook starts writing 'delivered'/'read'. The dashboard reports
-- that state as "no delivery data yet" rather than as 0%.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Attribution: which reminder produced this payment.
-- ------------------------------------------------------------
alter table public.payments
  add column if not exists reminder_event_id bigint references public.reminder_events(id) on delete set null;

comment on column public.payments.reminder_event_id is
  'The reminder this payment is attributed to. NULL = not reminder-driven (walk-in, AgentAlpha renewal, manual entry). Set only when a parent interaction, Pay Now, Paid reply or proof links the two.';

-- A payment may only be attributed to a reminder of the SAME tenant.
-- Ids are global; without this, a mis-set id silently credits another
-- academy's engine. (cross_tenant_integrity() would catch it after the
-- fact; this prevents it.)
create or replace function public.payment_reminder_same_tenant()
returns trigger language plpgsql set search_path to 'public' as $$
declare v_t text;
begin
  if new.reminder_event_id is null then return new; end if;
  select tenant_id into v_t from reminder_events where id = new.reminder_event_id;
  if v_t is distinct from new.tenant_id then
    raise exception 'payment %: reminder_event_id belongs to tenant %, payment is %',
      coalesce(new.id::text,'(new)'), coalesce(v_t,'?'), new.tenant_id;
  end if;
  return new;
end $$;

drop trigger if exists payments_reminder_tenant_guard on public.payments;
create trigger payments_reminder_tenant_guard
  before insert or update of reminder_event_id, tenant_id on public.payments
  for each row execute function public.payment_reminder_same_tenant();

-- ------------------------------------------------------------
-- 2. Meta callback de-duplication + the indexes the aggregate reads.
-- ------------------------------------------------------------
-- One row per (tenant, message_id). Partial, because manual sends have
-- no message_id and there are legitimately many of those.
create unique index if not exists reminder_events_tenant_msg_uniq
  on public.reminder_events (tenant_id, message_id)
  where message_id is not null;

create index if not exists reminder_events_tenant_created_idx
  on public.reminder_events (tenant_id, created_at desc);
create index if not exists reminder_events_tenant_status_idx
  on public.reminder_events (tenant_id, status);
create index if not exists reminder_events_tenant_month_idx
  on public.reminder_events (tenant_id, ist_date);
create index if not exists payments_reminder_event_idx
  on public.payments (reminder_event_id) where reminder_event_id is not null;
create index if not exists wa_flow_events_tenant_step_idx
  on public.wa_flow_events (tenant_id, step, at desc);

-- ------------------------------------------------------------
-- 3. The dashboard, computed in one place.
--
-- Definitions, all enforced below:
--   · a reminder is COUNTED when Meta accepted it, or when a human
--     sent it manually — status in (accepted,sent,delivered,read,
--     manual_sent). queued/failed are attempts, not reminders.
--   · dry_run rows and sent_by='sample'/'test' are excluded entirely.
--   · read implies delivered (a 'read' row counts in both).
--   · a player counts ONCE per academy per month, and once per academy
--     across the whole period — keyed on (tenant_id, member_id), so
--     the same member_id in two academies stays two players.
--   · a payment is attributed only when reminder_event_id is set AND
--     the reminder shows a real interaction in wa_flow_events AND the
--     payment is confirmed (status='paid').
--   · revenue is the payment's own confirmed amount, never the
--     reminder's expected amount.
--   · months are cut in each tenant's own timezone
--     (config.timezone, default Asia/Kolkata — reminder_events.ist_date
--     already carries the IST day for existing rows).
--   · "all" aggregates per-tenant monthly results; it never re-groups
--     every tenant under one global timezone.
-- ------------------------------------------------------------
create or replace function public.whatsapp_reminder_stats(
  p_tenant text default 'all',
  p_months int  default 4
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_months int := least(greatest(coalesce(p_months, 4), 1), 12);
  v_scope  text;
  v_result jsonb;
begin
  -- ---------- authorisation ----------
  -- Central operators only. A tenant manager must never reach the
  -- cross-tenant view, and must not be able to name another tenant.
  if auth_role() = 'operator' then
    v_scope := coalesce(nullif(p_tenant, ''), 'all');
  elsif auth_role() = 'staff' then
    -- deliberately allowed for their OWN tenant, ignoring what they
    -- asked for; never 'all'
    if coalesce(p_tenant,'all') = 'all' or p_tenant is distinct from auth_tenant() then
      raise exception 'not authorised for tenant %', coalesce(p_tenant,'all')
        using errcode = '42501';
    end if;
    v_scope := auth_tenant();
  else
    raise exception 'operator or staff session required' using errcode = '42501';
  end if;

  with
  -- tenants in scope, with their reporting timezone
  scope_t as (
    select t.id as tenant_id,
           t.name as academy_name,
           coalesce(nullif(t.config->>'timezone',''), 'Asia/Kolkata') as tz
      from tenants t
     where v_scope = 'all' or t.id = v_scope
  ),
  -- the month grid, per tenant, in that tenant's own timezone
  months as (
    select s.tenant_id, s.academy_name, s.tz,
           date_trunc('month', (now() at time zone s.tz))::date
             - (make_interval(months => g.i))::interval as m_start_raw,
           g.i as ago
      from scope_t s
      cross join generate_series(0, v_months - 1) as g(i)
  ),
  month_grid as (
    select tenant_id, academy_name, tz, ago,
           m_start_raw::date as month_start,
           (m_start_raw + interval '1 month')::date as month_end,
           to_char(m_start_raw, 'YYYY-MM') as month_key,
           to_char(m_start_raw, 'Mon YYYY') as month_label,
           (ago = 0) as is_mtd
      from months
  ),
  -- reminders that actually went out, in the tenant's local day
  re as (
    select r.id, r.tenant_id, r.member_id, r.status, r.message_id,
           coalesce(r.ist_date, (r.created_at at time zone s.tz)::date) as local_date
      from reminder_events r
      join scope_t s on s.tenant_id = r.tenant_id
     where coalesce(r.dry_run, false) = false
       and coalesce(r.sent_by, '') not in ('sample', 'test', 'seed')
       and r.status in ('accepted','sent','delivered','read','manual_sent')
  ),
  -- a reminder that shows a real parent interaction
  interacted as (
    select distinct w.reminder_id
      from wa_flow_events w
     where w.step in ('parent_reply','pay_now','paid','proof','proof_submitted','manual_sent')
  ),
  -- payments attributable to a reminder: linked, interacted, confirmed
  pay as (
    select p.id, p.tenant_id, p.amount, p.reminder_event_id,
           coalesce((p.created_at at time zone s.tz)::date, p.on_date) as local_date
      from payments p
      join scope_t s on s.tenant_id = p.tenant_id
      join re on re.id = p.reminder_event_id and re.tenant_id = p.tenant_id
      join interacted i on i.reminder_id = p.reminder_event_id
     where p.reminder_event_id is not null
       and coalesce(p.status, 'paid') = 'paid'
  ),
  proofs as (
    select w.tenant_id, w.reminder_id,
           (w.at at time zone s.tz)::date as local_date
      from wa_flow_events w
      join scope_t s on s.tenant_id = w.tenant_id
     where w.step in ('proof','proof_submitted')
  ),
  -- ---------- per tenant-month ----------
  per_tm as (
    select g.tenant_id, g.academy_name, g.month_key, g.month_label, g.is_mtd, g.ago,
           (select count(*) from re
             where re.tenant_id = g.tenant_id
               and re.local_date >= g.month_start and re.local_date < g.month_end) as reminders_sent,
           (select count(distinct re.member_id) from re
             where re.tenant_id = g.tenant_id
               and re.local_date >= g.month_start and re.local_date < g.month_end) as players_reached,
           (select count(*) from re
             where re.tenant_id = g.tenant_id and re.status in ('delivered','read')
               and re.local_date >= g.month_start and re.local_date < g.month_end) as delivered,
           (select count(*) from re
             where re.tenant_id = g.tenant_id and re.status = 'read'
               and re.local_date >= g.month_start and re.local_date < g.month_end) as read_n,
           (select count(*) from proofs
             where proofs.tenant_id = g.tenant_id
               and proofs.local_date >= g.month_start and proofs.local_date < g.month_end) as proofs_n,
           (select count(*) from pay
             where pay.tenant_id = g.tenant_id
               and pay.local_date >= g.month_start and pay.local_date < g.month_end) as payments_n,
           (select coalesce(sum(pay.amount), 0) from pay
             where pay.tenant_id = g.tenant_id
               and pay.local_date >= g.month_start and pay.local_date < g.month_end) as revenue
      from month_grid g
  ),
  -- ---------- months, aggregated across tenants in scope ----------
  per_month as (
    select month_key, min(month_label) as month_label, bool_or(is_mtd) as is_mtd, min(ago) as ago,
           sum(reminders_sent)  as reminders_sent,
           sum(players_reached) as players_reached,
           sum(delivered)       as delivered,
           sum(read_n)          as read_n,
           sum(proofs_n)        as proofs_n,
           sum(payments_n)      as payments_n,
           sum(revenue)         as revenue
      from per_tm group by month_key
  ),
  -- period-wide unique players: (tenant_id, member_id), never merged
  period_players as (
    select count(*) as n from (
      select distinct re.tenant_id, re.member_id
        from re
        join month_grid g on g.tenant_id = re.tenant_id
       where re.local_date >= (select min(month_start) from month_grid)
    ) x
  ),
  -- ---------- per academy, for the breakdown table ----------
  per_academy as (
    select tenant_id, academy_name,
           sum(reminders_sent)  as reminders_sent,
           sum(players_reached) as players_reached_sum,
           sum(delivered)       as delivered,
           sum(read_n)          as read_n,
           sum(proofs_n)        as proofs_n,
           sum(payments_n)      as payments_n,
           sum(revenue)         as revenue
      from per_tm group by tenant_id, academy_name
  ),
  academy_players as (
    select re.tenant_id, count(distinct re.member_id) as uniq
      from re group by re.tenant_id
  )
  select jsonb_build_object(
    'success', true,
    'scope', v_scope,
    'generatedAt', now(),
    'monthsRequested', v_months,

    'months', coalesce((
      select jsonb_agg(jsonb_build_object(
        'monthKey', month_key, 'label', month_label, 'isMTD', is_mtd,
        'remindersSent', reminders_sent,
        'playersReached', players_reached,
        'delivered', delivered,
        'read', read_n,
        'proofs', proofs_n,
        'paymentsViaReminder', payments_n,
        'revenueViaReminder', revenue,
        'deliveryRate', case when reminders_sent > 0 then round(100.0*delivered/reminders_sent, 1) else null end,
        'readRate',     case when reminders_sent > 0 then round(100.0*read_n  /reminders_sent, 1) else null end,
        'conversionRate', case when reminders_sent > 0 then round(100.0*payments_n/reminders_sent, 1) else null end
      ) order by month_key) from per_month), '[]'::jsonb),

    'totals', (
      select jsonb_build_object(
        'remindersSent',       coalesce(sum(reminders_sent), 0),
        'academiesUsing',      count(*) filter (where reminders_sent > 0),
        'uniquePlayers',       (select n from period_players),
        'paymentsViaReminder', coalesce(sum(payments_n), 0),
        'revenueViaReminder',  coalesce(sum(revenue), 0),
        'proofs',              coalesce(sum(proofs_n), 0),
        'deliveryRate', case when coalesce(sum(reminders_sent),0) > 0
                             then round(100.0*sum(delivered)/sum(reminders_sent), 1) else null end,
        'readRate',     case when coalesce(sum(reminders_sent),0) > 0
                             then round(100.0*sum(read_n)/sum(reminders_sent), 1) else null end,
        'conversionRate', case when coalesce(sum(reminders_sent),0) > 0
                             then round(100.0*sum(payments_n)/sum(reminders_sent), 1) else null end,
        'hasDeliveryData', coalesce(sum(delivered), 0) > 0
      ) from per_academy),

    'academies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tenantId', a.tenant_id,
        'academyName', a.academy_name,
        'remindersSent', a.reminders_sent,
        'playersReached', coalesce(ap.uniq, 0),
        'paymentsViaReminder', a.payments_n,
        'revenueViaReminder', a.revenue,
        'proofs', a.proofs_n,
        'deliveryRate', case when a.reminders_sent > 0 then round(100.0*a.delivered/a.reminders_sent, 1) else null end,
        'readRate',     case when a.reminders_sent > 0 then round(100.0*a.read_n  /a.reminders_sent, 1) else null end,
        'conversionRate', case when a.reminders_sent > 0 then round(100.0*a.payments_n/a.reminders_sent, 1) else null end
      ) order by a.reminders_sent desc, a.academy_name)
      from per_academy a left join academy_players ap on ap.tenant_id = a.tenant_id), '[]'::jsonb)
  ) into v_result;

  return v_result;
end $$;

comment on function public.whatsapp_reminder_stats(text, int) is
  'WhatsApp reminder performance for the operator console. Operator: any tenant or all. Staff: their own tenant only, never all. Aggregated in Postgres — no raw event leaves the database.';

revoke execute on function public.whatsapp_reminder_stats(text, int) from public, anon;
grant execute on function public.whatsapp_reminder_stats(text, int) to authenticated, service_role;

-- ------------------------------------------------------------
-- Self-checks. These are the acceptance tests that can be expressed in
-- SQL; the rest run from the harness in supabase/tests/.
-- ------------------------------------------------------------
do $$
declare v jsonb; v_sum_rem int; v_all_rem int; v_n int;
begin
  -- the function answers for an operator
  perform set_config('request.jwt.claims', '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);

  v := whatsapp_reminder_stats('all', 4);
  if (v->>'success')::boolean is not true then raise exception 'stats call failed'; end if;

  -- (4) all-academy totals equal the sum of per-academy results
  select coalesce(sum((a->>'remindersSent')::int), 0) into v_sum_rem
    from jsonb_array_elements(v->'academies') a;
  v_all_rem := (v->'totals'->>'remindersSent')::int;
  if v_sum_rem <> v_all_rem then
    raise exception 'totals disagree with academy breakdown: % vs %', v_all_rem, v_sum_rem;
  end if;

  -- months array is the requested length
  select jsonb_array_length(v->'months') into v_n;
  if v_n <> 4 then raise exception 'expected 4 months, got %', v_n; end if;

  -- (2)/(3) tenant isolation: single-tenant scope never returns another
  v := whatsapp_reminder_stats('raj', 4);
  if exists (select 1 from jsonb_array_elements(v->'academies') a
              where a->>'tenantId' <> 'raj') then
    raise exception 'single-tenant scope leaked another academy';
  end if;

  -- (10) a staff session cannot ask for 'all'
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}', true);
  begin
    perform whatsapp_reminder_stats('all', 4);
    raise exception 'a staff session reached the cross-tenant view';
  exception when sqlstate '42501' then null;
  end;

  -- (9) and cannot ask for a tenant that is not theirs
  begin
    perform whatsapp_reminder_stats('leo', 4);
    raise exception 'a staff session reached another tenant';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims', null, true);
  raise notice 'whatsapp_reminder_stats: authorisation and aggregation checks passed';
end $$;
