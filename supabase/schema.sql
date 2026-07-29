-- ============================================================
-- ACADEMY MANAGER — multi-tenant platform schema
-- Org: Academy Manager · Project: Leo Academy
-- Run this once in the Supabase SQL editor (Dashboard → SQL → New query).
-- Every table carries tenant_id so Gen Alpha and future academies
-- share this one database; 'leo' is seeded below.
-- ============================================================

create table if not exists tenants (
  id         text primary key,              -- 'leo', 'genalpha', ...
  name       text not null,
  config     jsonb not null default '{}',   -- courts, rates, UPI ids, templates
  created_at timestamptz not null default now()
);

create table if not exists members (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id),
  name       text not null,
  phone      text,
  program    text,
  joined     date,
  valid_till date,
  status     text not null default 'active',
  created_at timestamptz not null default now()
);
create index if not exists members_tenant_idx on members (tenant_id, status);

-- The availability ledger: ONE row per booked court-hour regardless of the
-- channel it came from (Website / Playo / Hudle / District / Walk-in).
-- This is the channel-manager core — a slot blocked here is blocked for
-- every surface that reads this table.
create table if not exists bookings (
  id         text primary key,              -- app-generated 'B-...' ids
  tenant_id  text not null references tenants(id),
  name       text not null,
  phone      text,
  sport      text not null default 'tennis',
  court      text,                          -- null until staff assign one
  date       date not null,
  hour       int  not null check (hour between 0 and 23),
  amount     int  not null,
  status     text not null default 'pending',  -- pending | confirmed | cancelled
  source     text not null default 'Website',
  created_at timestamptz not null default now()
);
create index if not exists bookings_tenant_date_idx on bookings (tenant_id, date);
-- a court can hold one active booking per hour
create unique index if not exists bookings_slot_unique
  on bookings (tenant_id, date, hour, court)
  where court is not null and status <> 'cancelled';

create table if not exists payments (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id),
  name       text,
  type       text,                          -- Membership | Court
  detail     text,
  amount     int,
  mode       text,                          -- UPI | Cash | Bank
  on_date    date,
  created_at timestamptz not null default now()
);
create index if not exists payments_tenant_idx on payments (tenant_id, on_date);

create table if not exists attendance (
  tenant_id  text not null references tenants(id),
  date       date not null,
  kind       text not null,                 -- member | staff
  person_id  text not null,
  present    boolean not null default true,
  primary key (tenant_id, date, kind, person_id)
);

create table if not exists reminders_log (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id),
  member_id  text not null,
  channel    text not null default 'whatsapp',
  upi_used   text,
  sent_at    timestamptz not null default now()
);

-- Usage analytics — feeds the central Academy Manager console.
create table if not exists events (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id),
  name       text not null,                 -- page_view, booking_submitted, ...
  props      jsonb not null default '{}',
  session_id text,
  page       text,
  at         timestamptz not null default now()
);
create index if not exists events_tenant_at_idx on events (tenant_id, at);

-- ------------------------------------------------------------
-- Row-level security. Phase 1 = anon key from the public apps may read
-- operational data and insert records; deletes are service-role only.
-- Tighten these to authenticated staff roles when Supabase Auth lands.
-- ------------------------------------------------------------
alter table tenants        enable row level security;
alter table members        enable row level security;
alter table bookings       enable row level security;
alter table payments       enable row level security;
alter table attendance     enable row level security;
alter table reminders_log  enable row level security;
alter table events         enable row level security;

create policy tenants_read      on tenants       for select using (true);
create policy members_read      on members       for select using (true);
create policy members_write     on members       for insert with check (true);
create policy members_update    on members       for update using (true);
create policy bookings_read     on bookings      for select using (true);
create policy bookings_write    on bookings      for insert with check (true);
create policy bookings_update   on bookings      for update using (true);
create policy payments_read     on payments      for select using (true);
create policy payments_write    on payments      for insert with check (true);
create policy attendance_read   on attendance    for select using (true);
create policy attendance_write  on attendance    for insert with check (true);
create policy attendance_update on attendance    for update using (true);
create policy reminders_write   on reminders_log for insert with check (true);
create policy reminders_read    on reminders_log for select using (true);
create policy events_write      on events        for insert with check (true);

-- ------------------------------------------------------------
-- Seed tenants
-- ------------------------------------------------------------
insert into tenants (id, name, config) values
  ('leo', 'Leo Tennis Academy',
   '{"brand":"Leo Academy","city":"Hyderabad",
     "courts":{"tennis":5,"pickleball":4},
     "rates":{"tennis":{"offPeak":500,"peak":700},"pickleball":{"offPeak":400,"peak":600},"peakFrom":16},
     "billing":{"payee":"Leo Academy","upiIds":["1234567890@ybl","0123456789@ybl"],"upiWindowDays":5}}'),
  ('genalpha', 'Gen Alpha Cricket Academy', '{"brand":"Gen Alpha","city":"Hyderabad"}')
on conflict (id) do nothing;
create table if not exists applications (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id),
  name       text not null,
  phone      text,
  email      text,
  level      text,
  goal       text,
  program    text,
  slot       text,
  trial_date date,
  created_at timestamptz not null default now()
);
create index if not exists applications_tenant_idx on applications (tenant_id, created_at desc);
alter table applications enable row level security;
create policy applications_read  on applications for select using (true);
create policy applications_write on applications for insert with check (true);

alter table payments add column if not exists ref text;
create unique index if not exists payments_ref_unique on payments (tenant_id, ref) where ref is not null;
-- the Academy Manager console reads usage analytics
create policy events_read on events for select using (true);
-- What each academy pays the platform (operator-only concept; the
-- tenant apps never read this). MRR amounts are PLACEHOLDERS — edit in
-- the dashboard or via SQL when real contracts are signed.
create table if not exists subscriptions (
  tenant_id  text primary key references tenants(id),
  plan       text not null default 'pilot',   -- pilot | standard | pro
  mrr        int  not null default 0,         -- ₹ per month
  status     text not null default 'active',  -- active | pilot | paused
  started    date,
  renews_on  date,
  notes      text
);
alter table subscriptions enable row level security;
create policy subscriptions_read on subscriptions for select using (true);

insert into subscriptions (tenant_id, plan, mrr, status, started, renews_on, notes) values
  ('leo',      'pilot',    2500, 'active', '2026-07-01', '2026-08-01', 'Won after demo — placeholder MRR, set real contract value'),
  ('genalpha', 'standard', 2000, 'active', '2026-06-01', '2026-08-01', 'First client — placeholder MRR')
on conflict (tenant_id) do nothing;
-- ============================================================
-- Migration 5 — trust layer, phase A (non-breaking)
-- Server-side pricing, atomic court assignment, PII-free public
-- availability. Strict per-role policies live in lockdown.sql and
-- are applied once auth users exist (platform_settings.lockdown).
-- ============================================================

create table if not exists platform_settings (key text primary key, value text not null);
insert into platform_settings values ('lockdown','false') on conflict (key) do nothing;
alter table platform_settings enable row level security;  -- no policies: service/definer access only

create or replace function is_locked() returns boolean language sql stable security definer
set search_path = public as
$$ select coalesce((select value from platform_settings where key='lockdown'),'false') = 'true' $$;

create or replace function auth_role() returns text language sql stable as
$$ select coalesce(auth.jwt()->'app_metadata'->>'am_role','') $$;

create or replace function auth_tenant() returns text language sql stable as
$$ select coalesce(auth.jwt()->'app_metadata'->>'tenant_id','') $$;

-- staff/operator guard that only bites after lockdown is enabled
create or replace function assert_staff(p_tenant text) returns void language plpgsql stable as $$
begin
  if not is_locked() then return; end if;
  if auth_role() = 'operator' then return; end if;
  if auth_role() = 'staff' and auth_tenant() = p_tenant then return; end if;
  raise exception 'not authorised';
end $$;

-- Public availability: slot occupancy WITHOUT names or phones.
-- Definer-owned view so anon never needs (and post-lockdown never has)
-- select on the bookings table itself.
create or replace view public_slots as
  select id, tenant_id, sport, date, hour, court, status
  from bookings where status <> 'cancelled';
grant select on public_slots to anon, authenticated;

-- Server-side pricing shared by all booking paths
create or replace function slot_rate(p_tenant text, p_sport text, p_hour int)
returns int language plpgsql stable as $$
declare v_cfg jsonb; v_amt int;
begin
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;
  v_amt := case when p_hour >= coalesce((v_cfg#>>'{rates,peakFrom}')::int, 16)
    then (v_cfg#>>('{rates,' || p_sport || ',peak}'))::int
    else (v_cfg#>>('{rates,' || p_sport || ',offPeak}'))::int end;
  if v_amt is null then raise exception 'unknown sport'; end if;
  return v_amt;
end $$;

-- Public booking request: price computed here, capacity enforced here.
create or replace function request_booking(
  p_tenant text, p_sport text, p_date date, p_hour int, p_name text, p_phone text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_courts int; v_taken int; v_amt int; v_id text;
begin
  if p_hour < 6 or p_hour > 22 then raise exception 'invalid hour'; end if;
  if p_date < current_date then raise exception 'date in the past'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name required'; end if;
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;
  v_amt := slot_rate(p_tenant, p_sport, p_hour);
  v_courts := coalesce((v_cfg#>>('{courts,' || p_sport || '}'))::int, 0);
  select count(*) into v_taken from bookings
    where tenant_id = p_tenant and date = p_date and hour = p_hour
      and sport = p_sport and status <> 'cancelled';
  if v_taken >= v_courts then raise exception 'slot full'; end if;
  v_id := 'B-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || '-' || p_hour;
  insert into bookings (id, tenant_id, name, phone, sport, date, hour, amount, status, source)
    values (v_id, p_tenant, trim(p_name), nullif(trim(coalesce(p_phone,'')),''),
            p_sport, p_date, p_hour, v_amt, 'pending', 'Website');
  return jsonb_build_object('id', v_id, 'amount', v_amt);
end $$;
grant execute on function request_booking to anon, authenticated;

-- Staff manual entry (Playo/Hudle/walk-in): priced server-side,
-- court claimed atomically (unique index arbitrates races).
create or replace function record_booking(
  p_tenant text, p_sport text, p_date date, p_hour int,
  p_name text, p_phone text, p_source text, p_court text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_amt int; v_id text; v_courts int; v_court text; i int;
begin
  perform assert_staff(p_tenant);
  select config into v_cfg from tenants where id = p_tenant;
  v_amt := slot_rate(p_tenant, p_sport, p_hour);
  v_id := 'B-M' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  if p_court is not null then
    insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source)
      values (v_id, p_tenant, p_name, p_phone, p_sport, p_court, p_date, p_hour, v_amt, 'confirmed', p_source);
    return jsonb_build_object('id', v_id, 'court', p_court);
  end if;
  v_courts := coalesce((v_cfg#>>('{courts,' || p_sport || '}'))::int, 0);
  for i in 1..v_courts loop
    v_court := upper(left(p_sport,1)) || i;
    begin
      insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source)
        values (v_id, p_tenant, p_name, p_phone, p_sport, v_court, p_date, p_hour, v_amt, 'confirmed', p_source);
      return jsonb_build_object('id', v_id, 'court', v_court);
    exception when unique_violation then null; -- court taken, try next
    end;
  end loop;
  raise exception 'all courts taken';
end $$;
grant execute on function record_booking to anon, authenticated;

-- Confirm a pending request: locks the row, claims a court atomically,
-- idempotent if already confirmed.
create or replace function confirm_booking(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_cfg jsonb; v_courts int; v_court text; i int;
begin
  select * into b from bookings where id = p_id for update;
  if not found then raise exception 'unknown booking'; end if;
  perform assert_staff(b.tenant_id);
  if b.status = 'confirmed' and b.court is not null then
    return jsonb_build_object('id', b.id, 'court', b.court);
  end if;
  if b.court is not null then
    update bookings set status = 'confirmed' where id = p_id;
    return jsonb_build_object('id', b.id, 'court', b.court);
  end if;
  select config into v_cfg from tenants where id = b.tenant_id;
  v_courts := coalesce((v_cfg#>>('{courts,' || b.sport || '}'))::int, 0);
  for i in 1..v_courts loop
    v_court := upper(left(b.sport,1)) || i;
    begin
      update bookings set status = 'confirmed', court = v_court where id = p_id;
      return jsonb_build_object('id', b.id, 'court', v_court);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'all courts taken';
end $$;
grant execute on function confirm_booking to anon, authenticated;
-- fix: concatenated jsonb paths need an explicit text[] cast
create or replace function slot_rate(p_tenant text, p_sport text, p_hour int)
returns int language plpgsql stable as $$
declare v_cfg jsonb; v_amt int;
begin
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;
  v_amt := case when p_hour >= coalesce((v_cfg#>>'{rates,peakFrom}')::int, 16)
    then (v_cfg#>>(array['rates', p_sport, 'peak']))::int
    else (v_cfg#>>(array['rates', p_sport, 'offPeak']))::int end;
  if v_amt is null then raise exception 'unknown sport'; end if;
  return v_amt;
end $$;

create or replace function court_count(p_cfg jsonb, p_sport text)
returns int language sql stable as
$$ select coalesce((p_cfg#>>(array['courts', p_sport]))::int, 0) $$;

create or replace function request_booking(
  p_tenant text, p_sport text, p_date date, p_hour int, p_name text, p_phone text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_courts int; v_taken int; v_amt int; v_id text;
begin
  if p_hour < 6 or p_hour > 22 then raise exception 'invalid hour'; end if;
  if p_date < current_date then raise exception 'date in the past'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name required'; end if;
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;
  v_amt := slot_rate(p_tenant, p_sport, p_hour);
  v_courts := court_count(v_cfg, p_sport);
  select count(*) into v_taken from bookings
    where tenant_id = p_tenant and date = p_date and hour = p_hour
      and sport = p_sport and status <> 'cancelled';
  if v_taken >= v_courts then raise exception 'slot full'; end if;
  v_id := 'B-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || '-' || p_hour;
  insert into bookings (id, tenant_id, name, phone, sport, date, hour, amount, status, source)
    values (v_id, p_tenant, trim(p_name), nullif(trim(coalesce(p_phone,'')),''),
            p_sport, p_date, p_hour, v_amt, 'pending', 'Website');
  return jsonb_build_object('id', v_id, 'amount', v_amt);
end $$;

create or replace function record_booking(
  p_tenant text, p_sport text, p_date date, p_hour int,
  p_name text, p_phone text, p_source text, p_court text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_amt int; v_id text; v_courts int; v_court text; i int;
begin
  perform assert_staff(p_tenant);
  select config into v_cfg from tenants where id = p_tenant;
  v_amt := slot_rate(p_tenant, p_sport, p_hour);
  v_id := 'B-M' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  if p_court is not null then
    insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source)
      values (v_id, p_tenant, p_name, p_phone, p_sport, p_court, p_date, p_hour, v_amt, 'confirmed', p_source);
    return jsonb_build_object('id', v_id, 'court', p_court);
  end if;
  v_courts := court_count(v_cfg, p_sport);
  for i in 1..v_courts loop
    v_court := upper(left(p_sport,1)) || i;
    begin
      insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source)
        values (v_id, p_tenant, p_name, p_phone, p_sport, v_court, p_date, p_hour, v_amt, 'confirmed', p_source);
      return jsonb_build_object('id', v_id, 'court', v_court);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'all courts taken';
end $$;

create or replace function confirm_booking(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_cfg jsonb; v_courts int; v_court text; i int;
begin
  select * into b from bookings where id = p_id for update;
  if not found then raise exception 'unknown booking'; end if;
  perform assert_staff(b.tenant_id);
  if b.status = 'confirmed' and b.court is not null then
    return jsonb_build_object('id', b.id, 'court', b.court);
  end if;
  if b.court is not null then
    update bookings set status = 'confirmed' where id = p_id;
    return jsonb_build_object('id', b.id, 'court', b.court);
  end if;
  select config into v_cfg from tenants where id = b.tenant_id;
  v_courts := court_count(v_cfg, b.sport);
  for i in 1..v_courts loop
    v_court := upper(left(b.sport,1)) || i;
    begin
      update bookings set status = 'confirmed', court = v_court where id = p_id;
      return jsonb_build_object('id', b.id, 'court', v_court);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'all courts taken';
end $$;
-- CourtSync needs: cancel (free a slot) + venues readable by their own staff
create or replace function cancel_booking(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype;
begin
  select * into b from bookings where id = p_id for update;
  if not found then raise exception 'unknown booking'; end if;
  perform assert_staff(b.tenant_id);
  update bookings set status = 'cancelled' where id = p_id;
  return jsonb_build_object('id', b.id, 'court', b.court, 'status', 'cancelled');
end $$;
grant execute on function cancel_booking to authenticated;

-- staff may read THEIR OWN tenant row (courts/rates config drive the grid)
drop policy if exists tenants_staff_r on tenants;
create policy tenants_staff_r on tenants for select
  using (auth_role() = 'staff' and id = auth_tenant());
-- ============================================================
-- Migration 7 — anti-abuse on the public booking path
-- Closes the verified DoS: anon could create unlimited pending
-- bookings with fake/no phone and exhaust a day's capacity.
-- No external service needed. Full OTP verification comes later.
-- ============================================================
create or replace function request_booking(
  p_tenant text, p_sport text, p_date date, p_hour int, p_name text, p_phone text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_courts int; v_taken int; v_amt int; v_id text;
  v_phone text; v_pending_phone int; v_pending_day int;
begin
  if p_hour < 6 or p_hour > 22 then raise exception 'invalid hour'; end if;
  if p_date < current_date then raise exception 'date in the past'; end if;
  if p_date > current_date + 90 then raise exception 'date too far ahead'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name required'; end if;
  -- require a real 10-digit phone: gives us an identity to rate-limit on
  v_phone := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  v_phone := right(v_phone, 10);

  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;

  -- self-cleaning: unconfirmed website requests older than 90 min evaporate,
  -- so junk can never pile up and block real customers
  delete from bookings
    where tenant_id = p_tenant and date = p_date and source = 'Website'
      and status = 'pending' and created_at < now() - interval '90 minutes';

  -- flood caps: per phone, and per venue-day
  select count(*) into v_pending_phone from bookings
    where phone = v_phone and status = 'pending' and source = 'Website';
  if v_pending_phone >= 5 then raise exception 'too many pending requests — wait for confirmation'; end if;

  v_courts := court_count(v_cfg, p_sport);
  select count(*) into v_pending_day from bookings
    where tenant_id = p_tenant and date = p_date and source = 'Website' and status = 'pending';
  if v_pending_day >= greatest(v_courts * 8, 24) then raise exception 'the desk is catching up on requests — please call to book'; end if;

  v_amt := slot_rate(p_tenant, p_sport, p_hour);
  select count(*) into v_taken from bookings
    where tenant_id = p_tenant and date = p_date and hour = p_hour
      and sport = p_sport and status <> 'cancelled';
  if v_taken >= v_courts then raise exception 'slot full'; end if;

  v_id := 'B-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || '-' || p_hour;
  insert into bookings (id, tenant_id, name, phone, sport, date, hour, amount, status, source)
    values (v_id, p_tenant, trim(p_name), v_phone, p_sport, p_date, p_hour, v_amt, 'pending', 'Website');
  return jsonb_build_object('id', v_id, 'amount', v_amt);
end $$;
-- ============================================================
-- Migration 8 — operator_portfolio(): one call returns per-tenant
-- rollups computed IN the database. Two wins:
--  · performance — the console makes 1 RPC instead of 5×N raw fetches
--  · data minimization — only aggregates leave the DB; member names,
--    phones and payment details never reach the operator's browser
-- Operator-only (self-checked; SECURITY DEFINER bypasses RLS).
-- ============================================================
create or replace function operator_portfolio()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select coalesce(jsonb_agg(obj order by ord), '[]'::jsonb) into result from (
    select t.created_at as ord, jsonb_build_object(
      'tenant_id', t.id,
      'name', t.name,
      'config', t.config,
      'plan', s.plan,
      'mrr', coalesce(s.mrr, 0),
      'sub_status', s.status,
      'renews_on', s.renews_on,
      'bookings_30d', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled'),
      'bookings_prev', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status<>'cancelled'),
      'gmv_30d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status='confirmed')
               + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-30),
      'gmv_prev', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status='confirmed')
                + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-60 and p.on_date < current_date-30),
      'apps_30d', (select count(*) from applications a where a.tenant_id=t.id and a.created_at >= current_date-30),
      'events_30d', (select count(*) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'sessions_30d', (select count(distinct session_id) from events e where e.tenant_id=t.id and e.at >= current_date-30 and e.session_id is not null),
      'active_days_30d', (select count(distinct e.at::date) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'last_event_at', (select max(at) from events e where e.tenant_id=t.id),
      'errors_30d', (select count(*) from events e where e.tenant_id=t.id and e.name='client_error' and e.at >= current_date-30),
      'app_ver', (select props->>'ver' from events e where e.tenant_id=t.id and e.name='page_view' and e.props ? 'ver' order by e.at desc limit 1),
      'channel_mix', (select coalesce(jsonb_object_agg(src, cnt), '{}'::jsonb) from
        (select coalesce(source,'Website') src, count(*) cnt from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled' group by 1) m),
      'weekly_gmv', (select coalesce(jsonb_agg(wk order by wknum desc), '[]'::jsonb) from
        (select g.n as wknum,
          (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date >= current_date-(g.n*7+6) and b.date <= current_date-(g.n*7))
          + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-(g.n*7+6) and p.on_date <= current_date-(g.n*7)) as wk
         from generate_series(0,7) g(n)) w),
      'usage_daily', (select coalesce(jsonb_object_agg(d::text, cnt), '{}'::jsonb) from
        (select e.at::date d, count(*) cnt from events e where e.tenant_id=t.id and e.at >= current_date-13 group by 1) u)
    ) as obj
    from tenants t left join subscriptions s on s.tenant_id = t.id
  ) x;
  return result;
end $$;
grant execute on function operator_portfolio to authenticated;
-- ============================================================
-- Migration 9 — plan tiers + overage + messaging-cost tracking
-- Tiers price by active-player headroom; when a tenant exceeds
-- its cap the operator sees it (charge more / upsell). Messaging
-- (WhatsApp reminders) is a per-message overhead we bill or absorb.
-- ============================================================
alter table subscriptions add column if not exists tier text;
alter table subscriptions add column if not exists player_cap int;
alter table subscriptions add column if not exists msg_rate numeric(6,2) default 0.35; -- ₹ per WhatsApp message

-- PLACEHOLDER tiers (user is still finalising): T1 up to 50 players @ ₹899
update subscriptions set tier='Tier 1', player_cap=50, mrr=899, msg_rate=0.35 where tenant_id='leo';
update subscriptions set tier='Tier 1', player_cap=50, mrr=899, msg_rate=0.35 where tenant_id='genalpha';

-- Seed Leo's roster into the DB so "active players" is a real number
-- (demo data — cleared by launch-reset.sql at go-live).
insert into members (tenant_id, name, phone, program, joined, valid_till, status) values
  ('leo','Kabir Nair','99490 55876','perf',    '2025-04-05', current_date+29, 'active'),
  ('leo','Arjun Malhotra','96031 74412','found','2026-03-01', current_date+60, 'active'),
  ('leo','Sneha Kulkarni','98495 20678','cardio','2026-06-02', current_date-3,  'due'),
  ('leo','Rohit Venkatesh','90000 87641','perf', '2025-03-02', current_date+58, 'active'),
  ('leo','Meera Iyer','98661 90035','found',     '2026-02-18', current_date+41, 'active'),
  ('leo','Adityan Pillai','96520 71148','private','2024-12-01', current_date-8,  'due'),
  ('leo','Farhan Sheikh','90104 22983','perf',   '2025-07-22', current_date+2,  'active'),
  ('leo','Divya Chandran','97010 38854','cardio','2025-10-08', current_date-1,  'due'),
  ('leo','Vikram Bhat','98850 61147','found',    '2026-05-12', current_date+33, 'active'),
  ('leo','Ananya Deshpande','98481 33290','perf','2026-01-10', current_date+19, 'active'),
  ('leo','Sanjay Reddy','98490 11223','cardio',  '2025-11-04', current_date+47, 'active'),
  ('leo','Nikhil Prasad','99890 44215','found',  '2025-09-15', current_date+25, 'active'),
  ('leo','Lakshmi Menon','98123 40987','private','2026-04-20', current_date+52, 'active'),
  ('leo','Tarun Agarwal','97654 12309','perf',   '2026-06-15', current_date+74, 'active')
on conflict do nothing;

-- extend operator_portfolio with tier / players / messaging cost
create or replace function operator_portfolio()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select coalesce(jsonb_agg(obj order by ord), '[]'::jsonb) into result from (
    select t.created_at as ord, jsonb_build_object(
      'tenant_id', t.id, 'name', t.name, 'config', t.config,
      'plan', s.plan, 'mrr', coalesce(s.mrr,0), 'sub_status', s.status, 'renews_on', s.renews_on,
      'tier', s.tier, 'player_cap', s.player_cap, 'msg_rate', coalesce(s.msg_rate,0.35),
      'active_players', (select count(*) from members m where m.tenant_id=t.id and m.status in ('active','due')),
      'msgs_30d', (select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30),
      'msg_cost_30d', round((select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30) * coalesce(s.msg_rate,0.35), 2),
      'bookings_30d', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled'),
      'bookings_prev', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status<>'cancelled'),
      'gmv_30d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status='confirmed')
               + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-30),
      'gmv_prev', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status='confirmed')
                + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-60 and p.on_date < current_date-30),
      'apps_30d', (select count(*) from applications a where a.tenant_id=t.id and a.created_at >= current_date-30),
      'events_30d', (select count(*) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'sessions_30d', (select count(distinct session_id) from events e where e.tenant_id=t.id and e.at >= current_date-30 and e.session_id is not null),
      'active_days_30d', (select count(distinct e.at::date) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'last_event_at', (select max(at) from events e where e.tenant_id=t.id),
      'errors_30d', (select count(*) from events e where e.tenant_id=t.id and e.name='client_error' and e.at >= current_date-30),
      'app_ver', (select props->>'ver' from events e where e.tenant_id=t.id and e.name='page_view' and e.props ? 'ver' order by e.at desc limit 1),
      'channel_mix', (select coalesce(jsonb_object_agg(src, cnt), '{}'::jsonb) from
        (select coalesce(source,'Website') src, count(*) cnt from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled' group by 1) m),
      'weekly_gmv', (select coalesce(jsonb_agg(wk order by wknum desc), '[]'::jsonb) from
        (select g.n as wknum,
          (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date >= current_date-(g.n*7+6) and b.date <= current_date-(g.n*7))
          + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-(g.n*7+6) and p.on_date <= current_date-(g.n*7)) as wk
         from generate_series(0,7) g(n)) w),
      'usage_daily', (select coalesce(jsonb_object_agg(d::text, cnt), '{}'::jsonb) from
        (select e.at::date d, count(*) cnt from events e where e.tenant_id=t.id and e.at >= current_date-13 group by 1) u)
    ) as obj
    from tenants t left join subscriptions s on s.tenant_id = t.id
  ) x;
  return result;
end $$;
-- ============================================================
-- Migration 10 — contacts (derived CRM), one-way from bookings.
-- A READ-ONLY view: the booking write path never touches it, so a
-- bug here can never fail a booking. security_invoker=on means staff
-- see only THEIR tenant's contacts (RLS on bookings applies).
-- Bookers are NOT members: this is a passive contact list, separate
-- from the managed roster and from tier billing.
-- ============================================================
create or replace view contacts
with (security_invoker = on) as
select
  b.tenant_id,
  regexp_replace(b.phone, '\D', '', 'g') as phone,
  (array_agg(b.name order by b.created_at desc))[1] as name,
  count(*) as bookings,
  sum(case when b.status = 'confirmed' then b.amount else 0 end) as spent,
  min(b.date) as first_seen,
  max(b.date) as last_seen
from bookings b
where b.phone is not null
  and length(regexp_replace(b.phone, '\D', '', 'g')) >= 10
  and b.status <> 'cancelled'
group by b.tenant_id, regexp_replace(b.phone, '\D', '', 'g');
grant select on contacts to authenticated;

-- operator sees only the COUNT (aggregate, no phone numbers leave the tenant)
create or replace function operator_portfolio()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select coalesce(jsonb_agg(obj order by ord), '[]'::jsonb) into result from (
    select t.created_at as ord, jsonb_build_object(
      'tenant_id', t.id, 'name', t.name, 'config', t.config,
      'plan', s.plan, 'mrr', coalesce(s.mrr,0), 'sub_status', s.status, 'renews_on', s.renews_on,
      'tier', s.tier, 'player_cap', s.player_cap, 'msg_rate', coalesce(s.msg_rate,0.35),
      'active_players', (select count(*) from members m where m.tenant_id=t.id and m.status in ('active','due')),
      'contacts_count', (select count(distinct regexp_replace(phone,'\D','','g')) from bookings b
                         where b.tenant_id=t.id and b.phone is not null
                           and length(regexp_replace(b.phone,'\D','','g'))>=10 and b.status<>'cancelled'),
      'msgs_30d', (select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30),
      'msg_cost_30d', round((select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30) * coalesce(s.msg_rate,0.35), 2),
      'bookings_30d', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled'),
      'bookings_prev', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status<>'cancelled'),
      'gmv_30d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status='confirmed')
               + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-30),
      'gmv_prev', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status='confirmed')
                + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-60 and p.on_date < current_date-30),
      'apps_30d', (select count(*) from applications a where a.tenant_id=t.id and a.created_at >= current_date-30),
      'events_30d', (select count(*) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'sessions_30d', (select count(distinct session_id) from events e where e.tenant_id=t.id and e.at >= current_date-30 and e.session_id is not null),
      'active_days_30d', (select count(distinct e.at::date) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'last_event_at', (select max(at) from events e where e.tenant_id=t.id),
      'errors_30d', (select count(*) from events e where e.tenant_id=t.id and e.name='client_error' and e.at >= current_date-30),
      'app_ver', (select props->>'ver' from events e where e.tenant_id=t.id and e.name='page_view' and e.props ? 'ver' order by e.at desc limit 1),
      'channel_mix', (select coalesce(jsonb_object_agg(src, cnt), '{}'::jsonb) from
        (select coalesce(source,'Website') src, count(*) cnt from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled' group by 1) m),
      'weekly_gmv', (select coalesce(jsonb_agg(wk order by wknum desc), '[]'::jsonb) from
        (select g.n as wknum,
          (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date >= current_date-(g.n*7+6) and b.date <= current_date-(g.n*7))
          + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-(g.n*7+6) and p.on_date <= current_date-(g.n*7)) as wk
         from generate_series(0,7) g(n)) w),
      'usage_daily', (select coalesce(jsonb_object_agg(d::text, cnt), '{}'::jsonb) from
        (select e.at::date d, count(*) cnt from events e where e.tenant_id=t.id and e.at >= current_date-13 group by 1) u)
    ) as obj
    from tenants t left join subscriptions s on s.tenant_id = t.id
  ) x;
  return result;
end $$;
-- ============================================================
-- Migration 11 — booking-channel MASTER LIST (single source of truth)
-- Channels were hardcoded separately in every app (drifted: District
-- was in the console + CourtSync but missing from the Leo app). Now
-- one list in the DB, read by all apps via get_channels(). Add a
-- channel here once → it appears in every booking form, channel chart,
-- and the operator breakdown.
-- ============================================================
insert into platform_settings (key, value) values
  ('channels', '[
    {"id":"Website","label":"Website","color":"#e8c268"},
    {"id":"Playo","label":"Playo","color":"#34d399"},
    {"id":"Hudle","label":"Hudle","color":"#cbe34f"},
    {"id":"District","label":"District","color":"#60a5fa"},
    {"id":"Walk-in","label":"Walk-in","color":"#9aa3b2"}
  ]')
on conflict (key) do update set value = excluded.value;

-- readable by the public apps (the list itself is not sensitive)
create or replace function get_channels()
returns jsonb language sql stable security definer set search_path = public as
$$ select coalesce((select value::jsonb from platform_settings where key = 'channels'), '[]'::jsonb) $$;
grant execute on function get_channels to anon, authenticated;
-- ============================================================
-- Migration 12 — HARDENING: transaction timeouts + application
-- anti-spam RPC (closes the cross-tenant application-pollution finding)
-- ============================================================
-- a stuck/idle transaction can no longer hold locks forever; a query
-- waiting on a lock gives up quickly instead of piling up
alter role authenticated set idle_in_transaction_session_timeout = '60s';
alter role authenticated set lock_timeout = '10s';
alter role anon set idle_in_transaction_session_timeout = '30s';
alter role anon set lock_timeout = '10s';

-- public coaching enquiries now go through a validated, rate-limited RPC
-- instead of a raw INSERT (which let anyone forge tenant_id / spam)
create or replace function submit_application(
  p_tenant text, p_name text, p_phone text, p_email text,
  p_level text, p_goal text, p_program text, p_slot text, p_trial date
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_phone text; v_recent int;
begin
  if (select 1 from tenants where id = p_tenant) is null then raise exception 'unknown academy'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name required'; end if;
  v_phone := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  v_phone := right(v_phone, 10);
  -- cap: one phone can lodge at most 3 enquiries per day
  select count(*) into v_recent from applications
    where phone = v_phone and created_at > now() - interval '1 day';
  if v_recent >= 3 then raise exception 'too many requests — we already have your enquiry'; end if;
  insert into applications (tenant_id, name, phone, email, level, goal, program, slot, trial_date)
    values (p_tenant, trim(p_name), v_phone, nullif(trim(coalesce(p_email,'')),''),
            p_level, p_goal, p_program, p_slot, p_trial);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function submit_application to anon, authenticated;

-- lock the raw insert: enquiries must come through the RPC now
drop policy if exists applications_public_w on applications;
-- ============================================================
-- Migration 13 — booker analytics + finance revenue streams
-- ============================================================
-- per-tenant booker stats (staff of the tenant, or operator)
create or replace function tenant_booker_stats(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;
  return jsonb_build_object(
    'total_bookings', (select count(*) from bookings where tenant_id = p_tenant and status <> 'cancelled'),
    'weekday_bookings', (select count(*) from bookings where tenant_id = p_tenant and status <> 'cancelled' and extract(isodow from date) < 6),
    'weekend_bookings', (select count(*) from bookings where tenant_id = p_tenant and status <> 'cancelled' and extract(isodow from date) >= 6),
    'booker_revenue_90d', (select coalesce(sum(amount),0) from bookings where tenant_id = p_tenant and status = 'confirmed' and date >= current_date - 90),
    'distinct_bookers', (select count(distinct regexp_replace(phone,'\D','','g')) from bookings
      where tenant_id = p_tenant and phone is not null and length(regexp_replace(phone,'\D','','g')) >= 10 and status <> 'cancelled')
  );
end $$;
grant execute on function tenant_booker_stats to authenticated;

-- monthly revenue by stream (memberships vs court by sport), last N months
create or replace function tenant_revenue_streams(p_tenant text, p_months int default 6)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;
  return (
    select coalesce(jsonb_agg(row order by m), '[]'::jsonb) from (
      select to_char(mo, 'Mon') as m, mo,
        (select coalesce(sum(amount),0) from payments p where p.tenant_id = p_tenant and p.type = 'Membership'
          and date_trunc('month', p.on_date) = mo) as memberships,
        (select coalesce(sum(amount),0) from bookings b where b.tenant_id = p_tenant and b.status = 'confirmed' and b.sport = 'tennis'
          and date_trunc('month', b.date) = mo) as tennis,
        (select coalesce(sum(amount),0) from bookings b where b.tenant_id = p_tenant and b.status = 'confirmed' and b.sport = 'pickleball'
          and date_trunc('month', b.date) = mo) as pickleball
      from generate_series(date_trunc('month', current_date) - ((p_months - 1) || ' months')::interval,
                           date_trunc('month', current_date), '1 month') mo
    ) x
  );
end $$;
grant execute on function tenant_revenue_streams to authenticated;

-- give operator_portfolio a couple of booker fields for the AM cross-tenant view
-- (weekend/weekday split + all-time bookings), reusing the existing function body
create or replace function operator_portfolio()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select coalesce(jsonb_agg(obj order by ord), '[]'::jsonb) into result from (
    select t.created_at as ord, jsonb_build_object(
      'tenant_id', t.id, 'name', t.name, 'config', t.config,
      'plan', s.plan, 'mrr', coalesce(s.mrr,0), 'sub_status', s.status, 'renews_on', s.renews_on,
      'tier', s.tier, 'player_cap', s.player_cap, 'msg_rate', coalesce(s.msg_rate,0.35),
      'active_players', (select count(*) from members m where m.tenant_id=t.id and m.status in ('active','due')),
      'contacts_count', (select count(distinct regexp_replace(phone,'\D','','g')) from bookings b
                         where b.tenant_id=t.id and b.phone is not null
                           and length(regexp_replace(b.phone,'\D','','g'))>=10 and b.status<>'cancelled'),
      'total_bookings', (select count(*) from bookings b where b.tenant_id=t.id and b.status<>'cancelled'),
      'weekend_bookings', (select count(*) from bookings b where b.tenant_id=t.id and b.status<>'cancelled' and extract(isodow from b.date)>=6),
      'weekday_bookings', (select count(*) from bookings b where b.tenant_id=t.id and b.status<>'cancelled' and extract(isodow from b.date)<6),
      'booker_rev_90d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date>=current_date-90),
      'msgs_30d', (select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30),
      'msg_cost_30d', round((select count(*) from reminders_log r where r.tenant_id=t.id and r.sent_at >= current_date-30) * coalesce(s.msg_rate,0.35), 2),
      'bookings_30d', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled'),
      'bookings_prev', (select count(*) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status<>'cancelled'),
      'gmv_30d', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status='confirmed')
               + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-30),
      'gmv_prev', (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.date >= current_date-60 and b.date < current_date-30 and b.status='confirmed')
                + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-60 and p.on_date < current_date-30),
      'apps_30d', (select count(*) from applications a where a.tenant_id=t.id and a.created_at >= current_date-30),
      'events_30d', (select count(*) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'sessions_30d', (select count(distinct session_id) from events e where e.tenant_id=t.id and e.at >= current_date-30 and e.session_id is not null),
      'active_days_30d', (select count(distinct e.at::date) from events e where e.tenant_id=t.id and e.at >= current_date-30),
      'last_event_at', (select max(at) from events e where e.tenant_id=t.id),
      'errors_30d', (select count(*) from events e where e.tenant_id=t.id and e.name='client_error' and e.at >= current_date-30),
      'app_ver', (select props->>'ver' from events e where e.tenant_id=t.id and e.name='page_view' and e.props ? 'ver' order by e.at desc limit 1),
      'channel_mix', (select coalesce(jsonb_object_agg(src, cnt), '{}'::jsonb) from
        (select coalesce(source,'Website') src, count(*) cnt from bookings b where b.tenant_id=t.id and b.date >= current_date-30 and b.status<>'cancelled' group by 1) m),
      'weekly_gmv', (select coalesce(jsonb_agg(wk order by wknum desc), '[]'::jsonb) from
        (select g.n as wknum,
          (select coalesce(sum(amount),0) from bookings b where b.tenant_id=t.id and b.status='confirmed' and b.date >= current_date-(g.n*7+6) and b.date <= current_date-(g.n*7))
          + (select coalesce(sum(amount),0) from payments p where p.tenant_id=t.id and p.on_date >= current_date-(g.n*7+6) and p.on_date <= current_date-(g.n*7)) as wk
         from generate_series(0,7) g(n)) w),
      'usage_daily', (select coalesce(jsonb_object_agg(d::text, cnt), '{}'::jsonb) from
        (select e.at::date d, count(*) cnt from events e where e.tenant_id=t.id and e.at >= current_date-13 group by 1) u)
    ) as obj
    from tenants t left join subscriptions s on s.tenant_id = t.id
  ) x;
  return result;
end $$;
-- ============================================================
-- Migration 14 — CHANNEL-PARTNER integrations (CourtSync)
-- Architecture: the bookings ledger stays the single source of truth.
-- A partner sync (Playo/Hudle/District) is just another CALLER that
-- writes into the ledger, keyed by the partner's own booking id
-- (ext_ref) for idempotency. Real APIs plug in via Supabase Edge
-- Functions (poller + webhook) — scaffolded in supabase/functions/.
-- partner_sync() below is a DUMMY that simulates a partner pushing a
-- booking, proving the end-to-end path.
-- ============================================================
alter table bookings add column if not exists ext_ref text;  -- partner's booking id
-- a partner booking id is unique per tenant+channel (idempotent sync)
create unique index if not exists bookings_ext_ref_unique
  on bookings (tenant_id, source, ext_ref) where ext_ref is not null;

create table if not exists integrations (
  tenant_id   text not null references tenants(id),
  channel     text not null,
  enabled     boolean not null default true,
  config      jsonb not null default '{}',   -- api keys / venue ids (encrypted in prod)
  last_sync_at timestamptz,
  last_result text,
  primary key (tenant_id, channel)
);
alter table integrations enable row level security;
create policy integrations_staff on integrations for select
  using (auth_role() = 'operator' or (auth_role() = 'staff' and tenant_id = auth_tenant()));

create table if not exists sync_log (
  id         bigint generated always as identity primary key,
  tenant_id  text not null,
  channel    text not null,
  action     text not null,          -- pull | push | webhook
  ext_ref    text,
  status     text not null,          -- ok | skipped | error
  detail     text,
  at         timestamptz not null default now()
);
alter table sync_log enable row level security;
create policy sync_log_staff on sync_log for select
  using (auth_role() = 'operator' or (auth_role() = 'staff' and tenant_id = auth_tenant()));

insert into integrations (tenant_id, channel, enabled, config) values
  ('leo','Playo',    true,  '{"venue_id":"leo-playo-demo"}'),
  ('leo','Hudle',    true,  '{"venue_id":"leo-hudle-demo"}'),
  ('leo','District', true,  '{"venue_id":"leo-district-demo"}')
on conflict (tenant_id, channel) do nothing;

-- DUMMY partner pull: simulates the partner returning one new booking,
-- writes it into the ledger via the same rules real syncs would use.
create or replace function partner_sync(p_tenant text, p_channel text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_courts int; v_sport text; v_date date; v_hour int; v_court text;
  v_ext text; v_amt int; v_id text; v_attempts int := 0; v_done boolean := false;
begin
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;
  if (select enabled from integrations where tenant_id = p_tenant and channel = p_channel) is not true then
    raise exception 'integration not enabled';
  end if;
  select config into v_cfg from tenants where id = p_tenant;
  v_ext := p_channel || '-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  -- find a free future slot (partners book ahead); try a few random ones
  while v_attempts < 12 and not v_done loop
    v_attempts := v_attempts + 1;
    v_sport := case when random() < 0.6 then 'tennis' else 'pickleball' end;
    v_courts := coalesce((v_cfg#>>(array['courts', v_sport]))::int, 0);
    v_date := current_date + (1 + floor(random()*10))::int;
    v_hour := 6 + floor(random()*16)::int;
    v_court := upper(left(v_sport,1)) || (1 + floor(random()*v_courts))::int;
    v_amt := slot_rate(p_tenant, v_sport, v_hour);
    v_id := 'B-EXT' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
    begin
      insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source, ext_ref)
        values (v_id, p_tenant, p_channel || ' booking', null, v_sport, v_court, v_date, v_hour, v_amt, 'confirmed', p_channel, v_ext);
      v_done := true;
    exception when unique_violation then null; -- slot taken, try another
    end;
  end loop;
  update integrations set last_sync_at = now(),
    last_result = case when v_done then 'imported 1 booking' else 'no free slots' end
    where tenant_id = p_tenant and channel = p_channel;
  insert into sync_log (tenant_id, channel, action, ext_ref, status, detail)
    values (p_tenant, p_channel, 'pull', v_ext, case when v_done then 'ok' else 'skipped' end,
            case when v_done then 'imported ' || v_court || ' ' || v_date else 'no free slot found' end);
  return jsonb_build_object('imported', case when v_done then 1 else 0 end, 'channel', p_channel,
                            'court', v_court, 'date', v_date);
end $$;
grant execute on function partner_sync to authenticated;
-- ============================================================
-- Migration 15 — cross-partner block propagation
-- When a slot is taken on ANY channel, immediately notify every OTHER
-- enabled channel to block it (the real channel-manager behaviour).
-- DUMMY: logs the outbound "block" call to sync_log; the real HTTP call
-- to Playo/Hudle/District lives in the partner-push Edge Function.
-- Fired from every write path so a booking from anywhere fans out.
-- ============================================================
create or replace function propagate_block(p_booking_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; ch text; notified text[] := '{}';
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status = 'cancelled' or b.court is null then return jsonb_build_object('notified', notified); end if;
  for ch in select channel from integrations where tenant_id = b.tenant_id and enabled and channel <> b.source loop
    insert into sync_log (tenant_id, channel, action, ext_ref, status, detail)
      values (b.tenant_id, ch, 'push', b.ext_ref, 'ok',
        'block ' || b.court || ' ' || to_char(b.date,'DD Mon') || ' ' || b.hour || ':00 (from ' || b.source || ')');
    notified := notified || ch;
  end loop;
  return jsonb_build_object('notified', notified, 'court', b.court);
end $$;
grant execute on function propagate_block to authenticated;

-- record_booking: propagate after a court is claimed
create or replace function record_booking(p_tenant text, p_sport text, p_date date, p_hour integer, p_name text, p_phone text, p_source text, p_court text DEFAULT NULL::text)
returns jsonb language plpgsql security definer set search_path = 'public' as $function$
declare v_cfg jsonb; v_amt int; v_id text; v_courts int; v_court text; i int;
begin
  perform assert_staff(p_tenant);
  select config into v_cfg from tenants where id = p_tenant;
  v_amt := slot_rate(p_tenant, p_sport, p_hour);
  v_id := 'B-M' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  if p_court is not null then
    insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source)
      values (v_id, p_tenant, p_name, p_phone, p_sport, p_court, p_date, p_hour, v_amt, 'confirmed', p_source);
    begin perform propagate_block(v_id); exception when others then null; end;
    return jsonb_build_object('id', v_id, 'court', p_court);
  end if;
  v_courts := court_count(v_cfg, p_sport);
  for i in 1..v_courts loop
    v_court := upper(left(p_sport,1)) || i;
    begin
      insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source)
        values (v_id, p_tenant, p_name, p_phone, p_sport, v_court, p_date, p_hour, v_amt, 'confirmed', p_source);
      begin perform propagate_block(v_id); exception when others then null; end;
      return jsonb_build_object('id', v_id, 'court', v_court);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'all courts taken';
end $function$;

-- confirm_booking: propagate once the pending request gets a court
create or replace function confirm_booking(p_id text)
returns jsonb language plpgsql security definer set search_path = 'public' as $function$
declare b bookings%rowtype; v_cfg jsonb; v_courts int; v_court text; i int;
begin
  select * into b from bookings where id = p_id for update;
  if not found then raise exception 'unknown booking'; end if;
  perform assert_staff(b.tenant_id);
  if b.status = 'confirmed' and b.court is not null then
    return jsonb_build_object('id', b.id, 'court', b.court);
  end if;
  if b.court is not null then
    update bookings set status = 'confirmed' where id = p_id;
    begin perform propagate_block(p_id); exception when others then null; end;
    return jsonb_build_object('id', b.id, 'court', b.court);
  end if;
  select config into v_cfg from tenants where id = b.tenant_id;
  v_courts := court_count(v_cfg, b.sport);
  for i in 1..v_courts loop
    v_court := upper(left(b.sport,1)) || i;
    begin
      update bookings set status = 'confirmed', court = v_court where id = p_id;
      begin perform propagate_block(p_id); exception when others then null; end;
      return jsonb_build_object('id', b.id, 'court', v_court);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'all courts taken';
end $function$;

-- partner_sync: an inbound partner booking fans a block out to the others
create or replace function partner_sync(p_tenant text, p_channel text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_courts int; v_sport text; v_date date; v_hour int; v_court text;
  v_ext text; v_amt int; v_id text; v_attempts int := 0; v_done boolean := false;
begin
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;
  if (select enabled from integrations where tenant_id = p_tenant and channel = p_channel) is not true then
    raise exception 'integration not enabled';
  end if;
  select config into v_cfg from tenants where id = p_tenant;
  v_ext := p_channel || '-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  while v_attempts < 12 and not v_done loop
    v_attempts := v_attempts + 1;
    v_sport := case when random() < 0.6 then 'tennis' else 'pickleball' end;
    v_courts := coalesce((v_cfg#>>(array['courts', v_sport]))::int, 0);
    v_date := current_date + (1 + floor(random()*10))::int;
    v_hour := 6 + floor(random()*16)::int;
    v_court := upper(left(v_sport,1)) || (1 + floor(random()*v_courts))::int;
    v_amt := slot_rate(p_tenant, v_sport, v_hour);
    v_id := 'B-EXT' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
    begin
      insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source, ext_ref)
        values (v_id, p_tenant, p_channel || ' booking', null, v_sport, v_court, v_date, v_hour, v_amt, 'confirmed', p_channel, v_ext);
      v_done := true;
    exception when unique_violation then null;
    end;
  end loop;
  if v_done then begin perform propagate_block(v_id); exception when others then null; end; end if;
  update integrations set last_sync_at = now(),
    last_result = case when v_done then 'imported 1 booking' else 'no free slots' end
    where tenant_id = p_tenant and channel = p_channel;
  insert into sync_log (tenant_id, channel, action, ext_ref, status, detail)
    values (p_tenant, p_channel, 'pull', v_ext, case when v_done then 'ok' else 'skipped' end,
            case when v_done then 'imported ' || v_court || ' ' || v_date else 'no free slot found' end);
  return jsonb_build_object('imported', case when v_done then 1 else 0 end, 'channel', p_channel, 'court', v_court, 'date', v_date);
end $$;
-- ============================================================
-- Migration 16 — CourtSync as a productisable sync ENGINE
-- 1) accounts: a tenant row can be kind 'academy' (uses the full app)
--    or 'standalone' (API-key only, never touches the academy app).
-- 2) durable job queue for outbound propagation (retry + backoff) —
--    the robust replacement for fire-and-forget.
-- 3) sync_ingest: the public API door for standalone venues.
-- Runtime note: the worker is a scheduled Edge Function that calls
-- process_sync_jobs(); the DUMMY processor here logs the "block" — real
-- partner HTTP goes in supabase/functions/sync-worker.
-- ============================================================
alter table tenants add column if not exists kind text not null default 'academy';  -- academy | standalone
alter table tenants add column if not exists api_key text;                            -- for standalone API access
create unique index if not exists tenants_api_key_uidx on tenants (api_key) where api_key is not null;

-- a demo standalone venue: not an academy, just wants channel sync
insert into tenants (id, name, kind, api_key, config) values
  ('demo-courts', 'Demo Sports Arena', 'standalone', 'cs_demo_key_ABC123',
   '{"city":"Bengaluru","courts":{"tennis":3,"pickleball":2},
     "rates":{"tennis":{"offPeak":500,"peak":700},"pickleball":{"offPeak":400,"peak":600},"peakFrom":16}}')
on conflict (id) do nothing;
insert into integrations (tenant_id, channel, enabled, config) values
  ('demo-courts','Playo', true, '{"venue_id":"demo-playo"}'),
  ('demo-courts','Hudle', true, '{"venue_id":"demo-hudle"}')
on conflict (tenant_id, channel) do nothing;

-- durable outbound job queue
create table if not exists sync_jobs (
  id          bigint generated always as identity primary key,
  tenant_id   text not null,
  channel     text not null,
  action      text not null default 'block',   -- block | unblock
  ext_ref     text,
  payload     jsonb not null default '{}',
  status      text not null default 'pending',  -- pending | done | failed
  attempts    int  not null default 0,
  next_run_at timestamptz not null default now(),
  last_error  text,
  created_at  timestamptz not null default now()
);
create index if not exists sync_jobs_ready on sync_jobs (next_run_at) where status = 'pending';
alter table sync_jobs enable row level security;
create policy sync_jobs_staff on sync_jobs for select
  using (auth_role() = 'operator' or (auth_role() = 'staff' and tenant_id = auth_tenant()));

-- propagate_block now ENQUEUES one job per other channel (durable, retryable)
create or replace function propagate_block(p_booking_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; ch text; queued text[] := '{}';
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status = 'cancelled' or b.court is null then return jsonb_build_object('queued', queued); end if;
  for ch in select channel from integrations where tenant_id = b.tenant_id and enabled and channel <> b.source loop
    insert into sync_jobs (tenant_id, channel, action, ext_ref, payload)
      values (b.tenant_id, ch, 'block', b.ext_ref,
        jsonb_build_object('court', b.court, 'date', b.date::text, 'hour', b.hour, 'source', b.source));
    queued := queued || ch;
  end loop;
  return jsonb_build_object('queued', queued);
end $$;

-- the worker: drains ready jobs with SKIP LOCKED (safe for concurrent workers),
-- retries with backoff, dead-letters after 5 tries. DUMMY = logs the push;
-- the real Edge Function does the partner HTTP call using the account's key.
create or replace function process_sync_jobs(p_limit int default 25)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j record; v_done int := 0; v_failed int := 0;
begin
  for j in
    select * from sync_jobs where status = 'pending' and next_run_at <= now()
    order by next_run_at limit p_limit for update skip locked
  loop
    begin
      -- REAL worker: perform the partner block/unblock HTTP call here.
      update sync_jobs set status = 'done', attempts = attempts + 1 where id = j.id;
      insert into sync_log (tenant_id, channel, action, ext_ref, status, detail)
        values (j.tenant_id, j.channel, 'push', j.ext_ref, 'ok',
          j.action || ' ' || coalesce(j.payload->>'court','') || ' ' || coalesce(j.payload->>'date','') ||
          ' ' || coalesce(j.payload->>'hour','') || ':00 (from ' || coalesce(j.payload->>'source','') || ')');
      v_done := v_done + 1;
    exception when others then
      update sync_jobs set attempts = attempts + 1,
        status = case when attempts + 1 >= 5 then 'failed' else 'pending' end,
        next_run_at = now() + ((attempts + 1) * 30 || ' seconds')::interval,
        last_error = SQLERRM
        where id = j.id;
      v_failed := v_failed + 1;
    end;
  end loop;
  return jsonb_build_object('processed', v_done, 'failed', v_failed);
end $$;
grant execute on function process_sync_jobs to authenticated;

-- STANDALONE public API: a non-tenant venue registers a booking with its
-- api_key; we ledger it and enqueue blocks to its other channels.
create or replace function sync_ingest(p_api_key text, p_source text, p_sport text, p_date date, p_hour int, p_court text, p_ext_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tenant text; v_amt int; v_id text;
begin
  select id into v_tenant from tenants where api_key = p_api_key;
  if v_tenant is null then raise exception 'invalid api key'; end if;
  v_amt := coalesce(slot_rate(v_tenant, p_sport, p_hour), 0);
  v_id := 'B-API' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  begin
    insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source, ext_ref)
      values (v_id, v_tenant, p_source || ' booking', null, p_sport, p_court, p_date, p_hour, v_amt, 'confirmed', p_source, p_ext_ref);
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end;
  begin perform propagate_block(v_id); exception when others then null; end;
  return jsonb_build_object('ok', true, 'booking', v_id);
end $$;
grant execute on function sync_ingest to anon, authenticated;
-- ============================================================
-- Migration 17 — per-account partner credentials, ENCRYPTED
-- Each account's partner API key is unique to that account and must
-- never sit in a readable column. We store it in Supabase Vault
-- (encrypted at rest); integrations.config keeps only a non-secret
-- reference (secret_id + venue_id). Only the worker (service role)
-- can decrypt; staff/operator never see the raw key.
-- ============================================================
create or replace function set_integration_secret(p_tenant text, p_channel text, p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_id uuid; v_existing uuid;
begin
  -- a tenant may set its own key; the operator may set any tenant's
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;
  if (select 1 from integrations where tenant_id = p_tenant and channel = p_channel) is null then
    raise exception 'unknown integration';
  end if;
  v_name := 'partner:' || p_tenant || ':' || p_channel;
  select id into v_existing from vault.secrets where name = v_name;
  if v_existing is not null then
    perform vault.update_secret(v_existing, p_secret);
    v_id := v_existing;
  else
    v_id := vault.create_secret(p_secret, v_name, 'partner API key for ' || p_tenant || '/' || p_channel);
  end if;
  update integrations set config = config || jsonb_build_object('secret_id', v_id::text)
    where tenant_id = p_tenant and channel = p_channel;
  return jsonb_build_object('ok', true, 'secret_id', v_id, 'stored', 'encrypted in Vault');
end $$;
grant execute on function set_integration_secret to authenticated;
-- ============================================================
-- Migration 18 — method-agnostic channel connection
-- A channel is connected by a METHOD (manual | autologin | api | ical)
-- plus whatever credential that method needs, stored ENCRYPTED in Vault.
-- The engine downstream (ledger, queue, worker) doesn't care which method;
-- only the adapter differs. This is the onboarding capture point.
-- ============================================================
create or replace function connect_integration(
  p_tenant text, p_channel text, p_method text, p_creds jsonb default null, p_enabled boolean default true
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_id uuid; v_existing uuid;
begin
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;
  if p_method not in ('manual','autologin','api','ical') then raise exception 'bad method'; end if;

  insert into integrations (tenant_id, channel, enabled, config)
    values (p_tenant, p_channel, p_enabled, jsonb_build_object('method', p_method))
  on conflict (tenant_id, channel) do update
    set enabled = p_enabled, config = integrations.config || jsonb_build_object('method', p_method);

  -- credentials (api key, or username+password for autologin) → Vault, never plaintext
  if p_creds is not null and p_creds <> '{}'::jsonb then
    v_name := 'partner:' || p_tenant || ':' || p_channel;
    select id into v_existing from vault.secrets where name = v_name;
    if v_existing is not null then perform vault.update_secret(v_existing, p_creds::text); v_id := v_existing;
    else v_id := vault.create_secret(p_creds::text, v_name, 'creds for ' || p_tenant || '/' || p_channel); end if;
    update integrations set config = config || jsonb_build_object('secret_id', v_id::text)
      where tenant_id = p_tenant and channel = p_channel;
  end if;
  return jsonb_build_object('ok', true, 'channel', p_channel, 'method', p_method, 'has_creds', (p_creds is not null and p_creds <> '{}'::jsonb));
end $$;
grant execute on function connect_integration to authenticated;

-- seed sensible defaults so the onboarding UI shows a starting state
update integrations set config = config || '{"method":"api"}' where config->>'method' is null;
-- ============================================================
-- Migration 19 — booking cancellation (weather/rain/maintenance) +
-- maintenance holds. Cancelling frees the slot AND queues an UNBLOCK
-- to reopen it on the partner channels.
-- ============================================================
alter table bookings add column if not exists cancel_reason text;

-- unblock the other channels when a slot is freed (mirror of propagate_block)
create or replace function propagate_unblock(p_booking_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; ch text; queued text[] := '{}';
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.court is null then return jsonb_build_object('queued', queued); end if;
  for ch in select channel from integrations where tenant_id = b.tenant_id and enabled and channel <> b.source loop
    insert into sync_jobs (tenant_id, channel, action, ext_ref, payload)
      values (b.tenant_id, ch, 'unblock', b.ext_ref,
        jsonb_build_object('court', b.court, 'date', b.date::text, 'hour', b.hour, 'source', b.source));
    queued := queued || ch;
  end loop;
  return jsonb_build_object('queued', queued);
end $$;
grant execute on function propagate_unblock to authenticated;

create or replace function cancel_booking(p_id text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype;
begin
  select * into b from bookings where id = p_id for update;
  if not found then raise exception 'unknown booking'; end if;
  perform assert_staff(b.tenant_id);
  update bookings set status = 'cancelled', cancel_reason = p_reason where id = p_id;
  if b.court is not null then begin perform propagate_unblock(p_id); exception when others then null; end; end if;
  return jsonb_build_object('id', b.id, 'court', b.court, 'status', 'cancelled');
end $$;
grant execute on function cancel_booking to authenticated;

-- block a specific court-hour for maintenance / rain (a zero-fee hold)
create or replace function block_maintenance(p_tenant text, p_sport text, p_date date, p_hour int, p_court text, p_reason text default 'Maintenance')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  perform assert_staff(p_tenant);
  v_id := 'B-MNT' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source, cancel_reason)
    values (v_id, p_tenant, coalesce(p_reason,'Maintenance'), null, p_sport, p_court, p_date, p_hour, 0, 'confirmed', 'Maintenance', null);
  begin perform propagate_block(v_id); exception when others then null; end;
  return jsonb_build_object('id', v_id, 'court', p_court);
end $$;
grant execute on function block_maintenance to authenticated;
-- ============================================================
-- Migration 19 — booking cancellation (weather/rain/maintenance) +
-- maintenance holds. Cancelling frees the slot AND queues an UNBLOCK
-- to reopen it on the partner channels.
-- ============================================================
alter table bookings add column if not exists cancel_reason text;

-- unblock the other channels when a slot is freed (mirror of propagate_block)
create or replace function propagate_unblock(p_booking_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; ch text; queued text[] := '{}';
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.court is null then return jsonb_build_object('queued', queued); end if;
  for ch in select channel from integrations where tenant_id = b.tenant_id and enabled and channel <> b.source loop
    insert into sync_jobs (tenant_id, channel, action, ext_ref, payload)
      values (b.tenant_id, ch, 'unblock', b.ext_ref,
        jsonb_build_object('court', b.court, 'date', b.date::text, 'hour', b.hour, 'source', b.source));
    queued := queued || ch;
  end loop;
  return jsonb_build_object('queued', queued);
end $$;
grant execute on function propagate_unblock to authenticated;

drop function if exists cancel_booking(text);
create or replace function cancel_booking(p_id text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype;
begin
  select * into b from bookings where id = p_id for update;
  if not found then raise exception 'unknown booking'; end if;
  perform assert_staff(b.tenant_id);
  update bookings set status = 'cancelled', cancel_reason = p_reason where id = p_id;
  if b.court is not null then begin perform propagate_unblock(p_id); exception when others then null; end; end if;
  return jsonb_build_object('id', b.id, 'court', b.court, 'status', 'cancelled');
end $$;
grant execute on function cancel_booking(text, text) to authenticated;

-- block a specific court-hour for maintenance / rain (a zero-fee hold)
create or replace function block_maintenance(p_tenant text, p_sport text, p_date date, p_hour int, p_court text, p_reason text default 'Maintenance')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  perform assert_staff(p_tenant);
  v_id := 'B-MNT' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS');
  insert into bookings (id, tenant_id, name, phone, sport, court, date, hour, amount, status, source, cancel_reason)
    values (v_id, p_tenant, coalesce(p_reason,'Maintenance'), null, p_sport, p_court, p_date, p_hour, 0, 'confirmed', 'Maintenance', null);
  begin perform propagate_block(v_id); exception when others then null; end;
  return jsonb_build_object('id', v_id, 'court', p_court);
end $$;
grant execute on function block_maintenance to authenticated;

-- ============ migration 20: platform health / reconciliation signals ============
-- ONE operator-only call that surfaces the sync engine's alarm signals:
-- job backlog + age (lag), dead-lettered jobs (failed 5x), and channels that
-- have gone stale (enabled but not synced in >6h). This is the "morning alert"
-- / reconciliation read; when real partner adapters land, a re-pull-and-diff
-- feeds the same surface. Operator-scoped so no tenant sees another's health.
create or replace function platform_health()
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  select jsonb_build_object(
    'as_of', now(),
    'jobs', jsonb_build_object(
      'pending', (select count(*) from sync_jobs where status = 'pending'),
      'failed',  (select count(*) from sync_jobs where status = 'failed'),
      'oldest_pending_mins',
        (select coalesce(round(extract(epoch from (now() - min(created_at))) / 60), 0)::int
           from sync_jobs where status = 'pending')
    ),
    'stale_integrations', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tenant_id', tenant_id, 'channel', channel,
        'last_sync_at', last_sync_at, 'last_result', last_result)), '[]'::jsonb)
      from integrations
      where enabled and (last_sync_at is null or last_sync_at < now() - interval '6 hours')
    ),
    'dead_letters', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'tenant_id', tenant_id, 'channel', channel,
        'action', action, 'attempts', attempts, 'last_error', last_error)), '[]'::jsonb)
      from sync_jobs where status = 'failed'
    )
  ) into result;
  return result;
end $$;
grant execute on function platform_health() to authenticated;

-- ============ migration 21: nightly reconciliation ============
-- Diff each day's ledger against what actually reached the other channels.
-- In our hub model, every confirmed booking on a court SHOULD have produced a
-- successful 'push' (block) to every OTHER enabled channel. A missing push =
-- drift (a slot that may still be sellable on a partner → double-book risk).
-- Also surfaces channels gone stale and failed jobs. Operator-only.
-- NOTE: matches pushes by court+date+hour in sync_log.detail; a production
-- build would match on a structured (channel,court,date,hour) key.
create or replace function reconcile_report(p_date date default current_date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if auth_role() <> 'operator' then raise exception 'operator only'; end if;
  with day_bookings as (
    select b.tenant_id, b.id, b.source, b.court, b.date, b.hour
    from bookings b
    where b.date = p_date and b.status = 'confirmed' and b.court is not null
  ),
  expected as (
    select db.tenant_id, db.id as booking_id, db.court, db.hour, i.channel
    from day_bookings db
    join integrations i
      on i.tenant_id = db.tenant_id and i.enabled and i.channel <> db.source
  ),
  gaps as (
    select e.*
    from expected e
    where not exists (
      select 1 from sync_log sl
      where sl.tenant_id = e.tenant_id and sl.channel = e.channel
        and sl.action = 'push' and sl.status = 'ok'
        and sl.detail like '%' || e.court || '%' || p_date::text || '%' || e.hour || ':00%'
    )
  )
  select jsonb_build_object(
    'date', p_date,
    'gap_count', (select count(*) from gaps),
    'propagation_gaps', (select coalesce(jsonb_agg(jsonb_build_object(
      'tenant_id', tenant_id, 'booking_id', booking_id, 'channel', channel,
      'court', court, 'hour', hour)), '[]'::jsonb) from gaps),
    'stale_channels', (select coalesce(jsonb_agg(jsonb_build_object(
      'tenant_id', tenant_id, 'channel', channel, 'last_sync_at', last_sync_at)), '[]'::jsonb)
      from integrations where enabled and (last_sync_at is null or last_sync_at < now() - interval '6 hours')),
    'failed_jobs', (select count(*) from sync_jobs where status = 'failed')
  ) into result;
  return result;
end $$;
grant execute on function reconcile_report(date) to authenticated;

-- ============ migration 22: pg_cron auto-sync (BaaS-native, LIVE) ============
-- The sync engine now runs on a schedule with NOBODY's app open — deployed via
-- pg_cron (1.6.4, already installed), no Edge Function / Docker needed:
--   cron 'drain-sync-jobs'  every minute  -> select process_sync_jobs(200)
--        drains the block/unblock queue, propagating to the other channels.
--   cron 'reconcile-check'  hourly        -> select cron_health_check()
--        flags propagation gaps / failed jobs into sync_log ('platform' tenant).
-- Proven end-to-end: a Playo booking -> propagate_block queues Hudle+District
-- blocks -> pg_cron drained them the same minute (sync_log push, status ok),
-- no manual trigger. Only the REAL partner HTTP call is still stubbed inside
-- process_sync_jobs (swap in the partner-push Edge Function once creds exist).
-- Scheduled from the Management API:
--   select cron.schedule('drain-sync-jobs','* * * * *', $$select process_sync_jobs(200)$$);
--   select cron.schedule('reconcile-check','0 * * * *', $$select cron_health_check()$$);
create or replace function cron_health_check()
returns void language plpgsql security definer set search_path = public as $$
declare v_gaps int; v_failed int;
begin
  select count(*) into v_failed from sync_jobs where status = 'failed';
  select count(*) into v_gaps from (
    select 1 from bookings b
    join integrations i on i.tenant_id = b.tenant_id and i.enabled and i.channel <> b.source
    where b.date = current_date and b.status = 'confirmed' and b.court is not null
      and not exists (
        select 1 from sync_log sl
        where sl.tenant_id = b.tenant_id and sl.channel = i.channel
          and sl.action = 'push' and sl.status = 'ok'
          and sl.detail like '%' || b.court || '%' || current_date::text || '%' || b.hour || ':00%')
  ) g;
  if v_gaps > 0 or v_failed > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform', '*', 'reconcile', case when v_failed > 0 then 'error' else 'warn' end,
        v_gaps || ' propagation gap(s), ' || v_failed || ' failed job(s)');
  end if;
end $$;

-- ============ migration 23: operating expenses ledger ============
-- Finance → Expenses. Mirrors payments: staff of the tenant write & read,
-- operator reads across tenants. The app writes via a plain insert (like
-- payments) and fails soft to LT.store if this table isn't present yet.
create table if not exists expenses (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id),
  ref        text,
  category   text not null,                 -- Salaries | Ground maintenance | Equipment | Rent | Power & utilities | Other
  payee      text,
  detail     text,
  amount     int not null,
  mode       text,                          -- Bank | UPI | Cash | Card
  on_date    date,
  created_at timestamptz not null default now()
);
create index if not exists expenses_tenant_idx on expenses (tenant_id, on_date desc);
alter table expenses enable row level security;
-- Phase-1 (pre-lockdown) permissive policies; the lockdown block below
-- replaces them with staff/operator rules to match payments.
drop policy if exists expenses_read  on expenses;
drop policy if exists expenses_write on expenses;
create policy expenses_read  on expenses for select using (true);
create policy expenses_write on expenses for insert with check (true);
-- Post-lockdown tightening (safe to run once auth_role()/auth_tenant() exist;
-- harmless no-op re-runs). Uncomment when applying lockdown for expenses:
--   drop policy if exists expenses_read  on expenses;
--   drop policy if exists expenses_write on expenses;
--   create policy expenses_staff_r on expenses for select
--     using (auth_role() = 'operator' or (auth_role() = 'staff' and tenant_id = auth_tenant()));
--   create policy expenses_staff_w on expenses for insert
--     with check (auth_role() = 'staff' and tenant_id = auth_tenant());
