-- ============================================================
-- 2026-08-19n · "Overdue" was telling us money was late when none was owed
-- scope: shared
--
-- THE CONFUSION, PRECISELY
--
-- The console showed Leo and GenAlpha as OVERDUE. Neither has ever been
-- invoiced. Leo's own subscription note reads "placeholder MRR, set real
-- contract value" and GenAlpha's reads "First client — placeholder MRR"
-- with mrr = 0. A red badge saying money is late, on an account that was
-- never asked for money.
--
-- Two separate faults, and the second is the real one.
--
-- 1. SIX STATUSES, THREE MEANINGS. `active` and `paid` did the same job;
--    `trial` and `pilot` did the same job; `overdue` was stored as a
--    status AND derived from a date, so the same fact had two homes that
--    could disagree.
--
-- 2. ONE DATE, TWO JOBS. `renews_on` meant "when the next invoice falls
--    due" for a paying account and "when this pilot gets reviewed" for
--    everyone else — and the badge treated a past date as money owed in
--    both cases. Every tenant is a pilot whose review date has passed, so
--    every tenant went red. That is the "same word, different shape" trap
--    from PLATFORM.md, in the billing column.
--
-- WHAT REPLACES IT
--
-- Four stored statuses, and a badge derived from status + date together
-- rather than from either alone:
--
--     free     using it, deliberately never billed        "Free"
--     trial    evaluating; renews_on is when the trial ENDS
--                                  future → "Trial · ends 1 Sep"
--                                  past   → "Trial ended"  (a decision is due)
--     paying   real money; renews_on is when the next invoice FALLS DUE
--                                  future → "Paying"
--                                  past   → "Overdue"      (money is late)
--     churned  stopped
--
-- **`overdue` is no longer a status anyone can store.** It is a thing
-- that can only be true of a `paying` account, which is the one rule that
-- makes the red badge mean what it says. A ₹0 account cannot be overdue,
-- because nobody owes ₹0 late.
--
-- PLACEHOLDER MRR IS ZEROED. Leo's ₹899 and MPP's ₹1,500 were invented to
-- make a dashboard look populated, and they were adding ₹2,399 of
-- imaginary revenue to the portfolio total. The old values move into
-- `notes` rather than vanishing, so the real contract value can be set
-- against what was assumed.
--
-- No tenant client reads any of this: only operator_portfolio(),
-- set_subscription(), demo_reset() and the console, all checked.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Move the existing rows to the new vocabulary
-- ------------------------------------------------------------
update subscriptions
   set notes = trim(both ' ·' from coalesce(notes, '') ||
                    case when mrr > 0 then ' · placeholder MRR was ' || mrr || '/mo (2026-08-19n)'
                         else '' end),
       mrr = 0
 where mrr > 0;

update subscriptions set status =
  case
    when tenant_id = 'demo'                     then 'free'
    when status in ('active','paid')            then 'paying'
    when status in ('cancelled','churned')      then 'churned'
    when status = 'overdue'                     then 'paying'   -- the DATE makes it overdue
    when status in ('trial','pilot')            then 'trial'
    else 'trial'
  end;

-- GenAlpha is used every day and is not being billed. That is a standing
-- decision, not a trial waiting on a verdict, so it says so.
update subscriptions set status = 'free',
       notes = trim(both ' ·' from coalesce(notes,'') || ' · first client, deliberately unbilled')
 where tenant_id = 'genalpha';

-- ------------------------------------------------------------
-- 2. Super Kings: testing until 1 Sep, live from 1 Sep
-- ------------------------------------------------------------
insert into subscriptions (tenant_id, plan, mrr, status, started, renews_on, notes)
values ('ska', 'standard', 0, 'trial', current_date, date '2026-09-01',
        'Evaluating. Testing through 31 Aug 2026; going live 1 Sep 2026. Set the contract value and flip to paying on the day.')
on conflict (tenant_id) do update
   set status = 'trial', renews_on = date '2026-09-01', notes = excluded.notes;

-- ------------------------------------------------------------
-- 3. Make the old vocabulary unrepresentable
--    subscriptions is OUR billing of tenants, not tenant data, so a
--    constraint here is data sanity and correctly binds every row.
-- ------------------------------------------------------------
alter table subscriptions drop constraint if exists subscriptions_status_ck;
alter table subscriptions add  constraint subscriptions_status_ck
  check (status in ('free','trial','paying','churned'));

comment on column subscriptions.status is
  'free | trial | paying | churned. NOT overdue — overdue is derived, and only a paying account can be it. A zero-MRR account never can.';
comment on column subscriptions.renews_on is
  'What this date means follows the status: for trial it is when the trial ENDS, for paying it is when the next invoice FALLS DUE. Ignored for free and churned. One date, one job at a time.';

-- ------------------------------------------------------------
-- 4. set_subscription() speaks the new vocabulary, and still
--    understands the old one so nothing that calls it breaks
-- ------------------------------------------------------------
create or replace function public.set_subscription(
  p_tenant text, p_status text default null, p_plan text default null,
  p_mrr numeric default null, p_renews_on date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_before jsonb; v_after jsonb;
  v_status text := nullif(trim(lower(p_status)), '');
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  if not exists (select 1 from tenants where id = p_tenant) then
    raise exception 'no such tenant: %', p_tenant;
  end if;

  -- The old names still work; they map rather than fail, because the
  -- point of this migration is to stop people having to know six words.
  v_status := case v_status
                when 'active'    then 'paying'
                when 'paid'      then 'paying'
                when 'pilot'     then 'trial'
                when 'cancelled' then 'churned'
                when 'overdue'   then 'paying'   -- see below
                else v_status end;

  if v_status is not null and v_status not in ('free','trial','paying','churned') then
    raise exception 'unknown status %; use free, trial, paying or churned', v_status;
  end if;

  select to_jsonb(s) into v_before from subscriptions s where s.tenant_id = p_tenant;

  if v_before is null then
    insert into subscriptions (tenant_id, plan, mrr, status, started, renews_on)
    values (p_tenant, coalesce(p_plan,'standard'), coalesce(p_mrr,0),
            coalesce(v_status,'trial'), current_date,
            coalesce(p_renews_on, (current_date + interval '1 month')::date));
  else
    update subscriptions
       set status    = coalesce(v_status, status),
           plan      = coalesce(p_plan, plan),
           mrr       = coalesce(p_mrr, mrr),
           -- Marking someone PAYING with a date already behind them would
           -- show them overdue a second later, which is how the old
           -- console produced its first false red. Roll it forward.
           renews_on = coalesce(
                         p_renews_on,
                         case when v_status = 'paying' and renews_on < current_date
                              then (current_date + interval '1 month')::date
                              else renews_on end)
     where tenant_id = p_tenant;
  end if;

  select to_jsonb(s) into v_after from subscriptions s where s.tenant_id = p_tenant;

  -- Same shape the previous version wrote: sync_log.channel and .status
  -- are NOT NULL, and detail is text, not jsonb. Kept identical so the
  -- billing history reads as one continuous series either side of this
  -- migration rather than changing shape halfway through.
  insert into sync_log (tenant_id, channel, action, status, detail)
  values (p_tenant, '*', 'subscription', 'ok',
          coalesce(v_before ->> 'status', '(none)') || ' -> ' || (v_after ->> 'status') ||
          ', mrr ' || coalesce(v_after ->> 'mrr', '0') ||
          ', renews ' || coalesce(v_after ->> 'renews_on', '-'));
  return v_after;
end $fn$;

revoke execute on function public.set_subscription(text,text,text,numeric,date) from public, anon;
grant  execute on function public.set_subscription(text,text,text,numeric,date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare r record; n int; v jsonb;
begin
  -- a) nothing is left speaking the old vocabulary
  select count(*) into n from subscriptions
   where status not in ('free','trial','paying','churned');
  if n > 0 then raise exception '% row(s) still on an old status', n; end if;

  -- b) nobody is paying, which is the stated fact of 2026-08-19
  select count(*) into n from subscriptions where status = 'paying' or mrr > 0;
  if n > 0 then raise exception '% row(s) still claim revenue', n; end if;

  -- c) SKA is trialling to 1 Sep
  select * into r from subscriptions where tenant_id = 'ska';
  if r.status <> 'trial' or r.renews_on <> date '2026-09-01' then
    raise exception 'ska is % until %', r.status, r.renews_on;
  end if;

  -- d) the constraint actually refuses the word that caused all this
  begin
    update subscriptions set status = 'overdue' where tenant_id = 'ska';
    raise exception 'overdue is still storable';
  exception when check_violation then null;
  end;

  -- e) an old caller still works, and cannot silently create revenue
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  v := set_subscription('ska', 'pilot');
  if v->>'status' <> 'trial' then
    raise exception 'the old word "pilot" mapped to %', v->>'status';
  end if;
  -- put it back exactly as this migration set it
  update subscriptions set status='trial', renews_on=date '2026-09-01' where tenant_id='ska';
  delete from sync_log where tenant_id='ska' and action='subscription'
     and at >= now() - interval '1 minute';
  perform set_config('request.jwt.claims', null, true);

  raise notice 'billing states: % free, % trial, % paying, % churned',
    (select count(*) from subscriptions where status='free'),
    (select count(*) from subscriptions where status='trial'),
    (select count(*) from subscriptions where status='paying'),
    (select count(*) from subscriptions where status='churned');
end $$;
