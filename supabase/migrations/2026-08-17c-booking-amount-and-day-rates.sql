-- ============================================================
-- 2026-08-17c · Booking: an amount and a collection at the point of sale,
--                and rates that can depend on the day of week.
-- scope: shared
--
-- Two problems, one code path, so one migration.
--
-- ------------------------------------------------------------
-- PROBLEM 1 — the operator cannot say what the booking cost
-- ------------------------------------------------------------
-- record_booking() prices solely through slot_rate() and offers no way to
-- override it, and it writes no record of the customer having PAID. So
-- taking a rental today is two screens: create the booking on the
-- bookings screen, then go to Finance and add the money separately.
-- Observed while demoing to a client, and it is the first thing they
-- flinched at — a counter transaction that takes two screens is a
-- counter transaction that will be half-done on a busy Saturday.
--
-- The fix is NOT a new "amount" field in the client. Money is computed in
-- Postgres; the client may only propose an override, and the server
-- decides the default. record_booking_v2 below takes an OPTIONAL amount:
-- null means "you price it", a value means "the operator negotiated this".
--
-- WHERE COLLECTION IS RECORDED, and why not in payments:
-- tenant_revenue_streams() already sums bookings.amount for rental
-- revenue and reads payments only for type='Membership'. So a payments
-- row per booking would be the SAME rupee counted twice, in a function
-- nobody would think to re-read. Rental money already lives on the
-- booking; what was missing is whether it was collected, how, and by
-- whom. Hence three columns on the booking itself, and no payments row.
--
-- WHY THESE COLUMNS BELONG ON A SHARED TABLE:
-- PLATFORM.md's rule is that a shared column must be something EVERY
-- tenant needs, and that a field earns promotion the moment a shared
-- function reads it. "Was this rental paid?" is not a Super Kings
-- question — Leo, MatchPoint and the demo all sell court time and all
-- have the same hole. record_booking_v2() is a shared function and reads
-- them. Both tests pass, so they are columns, not jsonb.
--
-- All three are NULLABLE with no default: every existing row stays
-- exactly as it is, and null honestly means "we never recorded it"
-- rather than silently asserting those bookings were unpaid.
--
-- ------------------------------------------------------------
-- PROBLEM 2 — slot_rate() cannot express a weekday price
-- ------------------------------------------------------------
-- Super Kings rents a full cricket ground at ₹10,000 Mon–Thu, ₹20,000
-- Friday, ₹25,000 Sat–Sun. slot_rate(tenant, sport, hour) takes no date,
-- so it cannot know the weekday; its only axis is a peakFrom cutoff.
--
-- slot_rate() IS NOT MODIFIED. It is called by Leo, MatchPoint and the
-- demo, and changing a money function used by three live apps to serve a
-- fourth is how one tenant breaks another. Instead slot_price() adds the
-- date axis and DELEGATES to slot_rate() whenever the sport has no
-- 'daily' block — so for every existing tenant the answer is byte-for-
-- byte what it is today, by construction rather than by testing.
--
-- WEEKDAY LOOKUP USES isodow, NOT to_char(date,'dy'). to_char's day names
-- follow the server's lc_time; a locale change would silently shift every
-- ground rate by one day, which is the kind of failure that reads as a
-- pricing dispute months later. isodow is an integer and is locale-proof.
--
-- ------------------------------------------------------------
-- FULL-DAY BOOKINGS AND THE DOUBLE-SELL GUARD
-- ------------------------------------------------------------
-- bookings_slot_unique is on (tenant_id, date, hour, court). A facility
-- marked fullDay is sold by the day, so every one of its bookings is
-- forced to hour = 0 here, server-side. That is what makes the EXISTING
-- unique index prevent double-selling the ground for a date.
--
-- If the client were trusted to send hour = 0, an operator creating a
-- ground booking at 14:00 would not collide with one at 00:00 and the
-- ground would be sold twice for the same day. Forcing it in SQL is the
-- difference between a convention and a guarantee.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Collection, on the booking.
-- ------------------------------------------------------------
alter table bookings add column if not exists paid_at      timestamptz;
alter table bookings add column if not exists paid_mode    text;
alter table bookings add column if not exists collected_by text;

comment on column bookings.paid_at is
  'When the rental was collected. NULL = not collected, or predates 2026-08-17c. Rental revenue is bookings.amount; there is deliberately no payments row per booking (tenant_revenue_streams would double-count it).';
comment on column bookings.paid_mode is
  'cash | upi | card | bank | null. Free text by design: tenants collect in ways the platform should not have to enumerate up front.';

-- ------------------------------------------------------------
-- 2. Date-aware pricing.
--
-- Returns the price for one slot. Falls through to slot_rate() unless the
-- facility declares a 'daily' block, so existing tenants are unaffected.
-- ------------------------------------------------------------
create or replace function slot_price(p_tenant text, p_sport text, p_date date, p_hour int)
returns int
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_cfg   jsonb;
  v_sport jsonb;
  v_amt   int;
  v_day   text;
  -- isodow: 1 = Monday … 7 = Sunday. Fixed, locale-proof.
  v_days  text[] := array['mon','tue','wed','thu','fri','sat','sun'];
begin
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then
    raise exception 'unknown academy';
  end if;

  v_sport := v_cfg #> array['rates', p_sport];
  if v_sport is null then
    -- Same wording as slot_rate, so callers that match on the message
    -- keep working.
    raise exception 'unknown sport';
  end if;

  if v_sport ? 'daily' then
    v_day := v_days[extract(isodow from p_date)::int];
    v_amt := (v_sport #>> array['daily', v_day])::int;
    if v_amt is null then
      raise exception 'no daily rate configured for %', v_day;
    end if;
    return v_amt;
  end if;

  -- No daily block: behave exactly as today.
  return slot_rate(p_tenant, p_sport, p_hour);
end
$function$;

-- ------------------------------------------------------------
-- 3. Is this facility sold by the day?
-- ------------------------------------------------------------
create or replace function is_full_day(p_tenant text, p_sport text)
returns boolean
language sql
stable
set search_path to 'public'
as $function$
  select coalesce((select config #>> array['rates', p_sport, 'fullDay'] from tenants where id = p_tenant)::boolean, false)
$function$;

-- ------------------------------------------------------------
-- 4. Book, price and collect in one call.
--
-- Mirrors record_booking's court-claiming loop rather than calling it,
-- because the loop's whole purpose is to insert and catch
-- unique_violation — it cannot be wrapped without losing the atomicity
-- that stops two operators selling the same net.
--
-- record_booking() is left in place and untouched: it is the signature
-- the existing tenant apps call, and PLATFORM.md ships breaking changes
-- as _v2 precisely so a client that cannot be force-updated keeps working.
-- ------------------------------------------------------------
create or replace function record_booking_v2(
  p_tenant       text,
  p_sport        text,
  p_date         date,
  p_hour         int,
  p_name         text,
  p_phone        text,
  p_source       text     default 'Counter',
  p_court        text     default null,
  p_amount       int      default null,   -- null = price it server-side
  p_paid         boolean  default false,
  p_mode         text     default null,
  p_collected_by text     default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cfg    jsonb;
  v_amt    int;
  v_id     text;
  v_courts int;
  v_court  text;
  v_hour   int;
  v_paid   timestamptz;
  i        int;
begin
  perform assert_staff(p_tenant);

  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then
    raise exception 'unknown academy';
  end if;

  -- A full-day facility is always hour 0. See header: this is the
  -- double-sell guard, so it is decided here and not by the caller.
  v_hour := case when is_full_day(p_tenant, p_sport) then 0 else p_hour end;

  -- The server prices it; an operator may override with a negotiated
  -- amount. A negative amount is refused — a refund is a cancellation,
  -- not a booking.
  v_amt := coalesce(p_amount, slot_price(p_tenant, p_sport, p_date, v_hour));
  if v_amt < 0 then
    raise exception 'amount may not be negative';
  end if;

  v_paid := case when p_paid then now() else null end;
  v_id   := 'B-M' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS');

  -- Explicit court: take it or fail. No silent reassignment — an
  -- operator who picked Astro Net 2 must not be given Matting Net 1.
  if p_court is not null then
    insert into bookings (id, tenant_id, name, phone, sport, court, date, hour,
                          amount, status, source, paid_at, paid_mode, collected_by)
      values (v_id, p_tenant, p_name, p_phone, p_sport, p_court, p_date, v_hour,
              v_amt, 'confirmed', p_source, v_paid, p_mode, p_collected_by);
    begin perform propagate_block(v_id); exception when others then null; end;
    return jsonb_build_object('id', v_id, 'court', p_court, 'amount', v_amt,
                              'hour', v_hour, 'paid', p_paid);
  end if;

  -- Otherwise take the first free one.
  v_courts := court_count(v_cfg, p_sport);
  for i in 1..v_courts loop
    v_court := upper(left(p_sport, 1)) || i;
    begin
      insert into bookings (id, tenant_id, name, phone, sport, court, date, hour,
                            amount, status, source, paid_at, paid_mode, collected_by)
        values (v_id, p_tenant, p_name, p_phone, p_sport, v_court, p_date, v_hour,
                v_amt, 'confirmed', p_source, v_paid, p_mode, p_collected_by);
      begin perform propagate_block(v_id); exception when others then null; end;
      return jsonb_build_object('id', v_id, 'court', v_court, 'amount', v_amt,
                                'hour', v_hour, 'paid', p_paid);
    exception when unique_violation then null;
    end;
  end loop;

  raise exception 'all courts taken';
end
$function$;

-- ------------------------------------------------------------
-- 5. Record collection against a booking that was made unpaid.
--
-- The counter case is "book now, pay when they arrive". Without this the
-- operator is back to two screens, which is the problem this migration
-- exists to remove.
-- ------------------------------------------------------------
create or replace function collect_booking(
  p_id           text,
  p_mode         text default null,
  p_collected_by text default null,
  p_amount       int  default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_tenant text; v_amt int; v_paid timestamptz;
begin
  select tenant_id, amount, paid_at into v_tenant, v_amt, v_paid
    from bookings where id = p_id;
  if v_tenant is null then
    raise exception 'no such booking';
  end if;
  perform assert_staff(v_tenant);

  if v_paid is not null then
    raise exception 'booking % was already collected at %', p_id, v_paid;
  end if;
  if p_amount is not null and p_amount < 0 then
    raise exception 'amount may not be negative';
  end if;

  update bookings
     set paid_at      = now(),
         paid_mode    = p_mode,
         collected_by = p_collected_by,
         amount       = coalesce(p_amount, amount)
   where id = p_id;

  select amount into v_amt from bookings where id = p_id;
  return jsonb_build_object('id', p_id, 'amount', v_amt, 'paid', true);
end
$function$;

-- ------------------------------------------------------------
-- 6. Grants.
--
-- The default grant on a new function is to PUBLIC, and `revoke … from
-- anon` alone is a no-op — the grant that matters is the bare =X/postgres
-- in the ACL. Revoke from public FIRST, then grant back deliberately.
--
-- slot_price and is_full_day are readable pricing, not writers, but they
-- take a tenant argument and are SECURITY-neutral (invoker, stable), so
-- they follow the same default-closed shape.
-- ------------------------------------------------------------
revoke execute on function slot_price(text, text, date, int)        from public, anon;
revoke execute on function is_full_day(text, text)                  from public, anon;
revoke execute on function record_booking_v2(text, text, date, int, text, text, text, text, int, boolean, text, text) from public, anon;
revoke execute on function collect_booking(text, text, text, int)   from public, anon;

grant execute on function slot_price(text, text, date, int)         to authenticated, service_role;
grant execute on function is_full_day(text, text)                   to authenticated, service_role;
grant execute on function record_booking_v2(text, text, date, int, text, text, text, text, int, boolean, text, text) to authenticated, service_role;
grant execute on function collect_booking(text, text, text, int)    to authenticated, service_role;

-- ------------------------------------------------------------
-- 7. Prove it, in the transaction that made it.
--
-- Asserting on VALUES, not on row counts: the platform has already been
-- bitten by a check that could not tell an error from data.
-- ------------------------------------------------------------
do $$
declare v_mon date; v_fri date; v_sat date;
begin
  -- Find a known Monday/Friday/Saturday so the assertions do not depend
  -- on what day this migration happens to be applied.
  v_mon := date '2026-08-17';                 -- a Monday
  v_fri := v_mon + 4;
  v_sat := v_mon + 5;

  if extract(isodow from v_mon) <> 1 then raise exception 'test fixture is not a Monday'; end if;

  -- Super Kings: the weekday ladder must come out of Postgres, not a client.
  if slot_price('ska', 'ground', v_mon, 0) <> 10000 then
    raise exception 'Mon ground rate is %, expected 10000', slot_price('ska','ground',v_mon,0);
  end if;
  if slot_price('ska', 'ground', v_fri, 0) <> 20000 then
    raise exception 'Fri ground rate is %, expected 20000', slot_price('ska','ground',v_fri,0);
  end if;
  if slot_price('ska', 'ground', v_sat, 0) <> 25000 then
    raise exception 'Sat ground rate is %, expected 25000', slot_price('ska','ground',v_sat,0);
  end if;

  -- The nets have no daily block, so they must delegate and be flat.
  if slot_price('ska', 'nets', v_sat, 19) <> 500 then
    raise exception 'net rate is %, expected 500', slot_price('ska','nets',v_sat,19);
  end if;

  -- fullDay classification drives the hour-0 guard.
  if not is_full_day('ska', 'ground') then raise exception 'ground should be fullDay'; end if;
  if is_full_day('ska', 'nets')       then raise exception 'nets should not be fullDay'; end if;

  -- REGRESSION: every existing tenant must price EXACTLY as before.
  -- demo has no daily block anywhere, so slot_price must equal slot_rate
  -- for every sport and every hour it is asked about.
  if slot_price('demo', 'tennis',    date '2026-08-17', 9)  <> slot_rate('demo', 'tennis',    9)  then
    raise exception 'demo tennis off-peak drifted';
  end if;
  if slot_price('demo', 'tennis',    date '2026-08-17', 19) <> slot_rate('demo', 'tennis',    19) then
    raise exception 'demo tennis peak drifted';
  end if;
  if slot_price('demo', 'badminton', date '2026-08-22', 20) <> slot_rate('demo', 'badminton', 20) then
    raise exception 'demo badminton drifted';
  end if;

  -- An unknown sport must still raise, not return null and price at zero.
  begin
    perform slot_price('ska', 'squash', v_mon, 10);
    raise exception 'slot_price accepted an unknown sport';
  exception when others then
    if sqlerrm <> 'unknown sport' then raise; end if;
  end;
end $$;
