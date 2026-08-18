-- ============================================================
-- Behaviour test for 2026-08-17c.
--
-- Proves what reading the SQL cannot: that the ground cannot be sold
-- twice for one day even when the second operator picks a different
-- hour, that the weekday ladder comes out of Postgres, that an operator
-- override reaches the row, and that a staff member of one tenant cannot
-- book for another.
--
-- Runs under a REAL staff-of-ska JWT, set below, because assert_staff()
-- reads auth.jwt() and a test that bypasses it proves nothing about the
-- guard. Wrapped in begin/rollback by the caller — it writes to shared
-- bookings and must keep nothing.
-- ============================================================

-- A staff member of ska, exactly as Supabase would present one.
set local request.jwt.claims = '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}';

do $$
declare
  v_sat date := date '2026-09-05';   -- a Saturday
  v_mon date := date '2026-09-07';   -- the Monday after
  r     jsonb;
  v_row bookings;
begin
  if extract(isodow from v_sat) <> 6 then raise exception 'fixture is not a Saturday'; end if;
  if extract(isodow from v_mon) <> 1 then raise exception 'fixture is not a Monday'; end if;

  -- ---------------------------------------------------------
  -- 1. Saturday ground = ₹25,000, forced to hour 0, court G1.
  -- ---------------------------------------------------------
  r := record_booking_v2('ska', 'ground', v_sat, 9, 'TEST Saturday', '9000000001');
  if (r->>'amount')::int <> 25000 then
    raise exception 'Saturday ground priced at %, expected 25000', r->>'amount';
  end if;
  if (r->>'hour')::int <> 0 then
    raise exception 'full-day booking kept hour %, expected 0', r->>'hour';
  end if;
  if r->>'court' <> 'G1' then
    raise exception 'ground booking landed on court %, expected G1', r->>'court';
  end if;

  -- ---------------------------------------------------------
  -- 2. THE DOUBLE-SELL GUARD.
  --
  -- A second operator books the same ground, same date, but types a
  -- different hour. Without the server forcing hour 0 this would insert
  -- happily and the ground would be sold twice for one Saturday.
  -- ---------------------------------------------------------
  begin
    r := record_booking_v2('ska', 'ground', v_sat, 14, 'TEST double sell', '9000000002');
    raise exception 'THE GROUND WAS SOLD TWICE for % — hour forcing is broken', v_sat;
  exception when others then
    if sqlerrm not like 'all courts taken%' then raise; end if;
  end;

  -- ---------------------------------------------------------
  -- 3. Monday is a different day and must still be bookable, at ₹10,000.
  --    (A guard that blocks the second sale by blocking everything is
  --    the failure mode anon_probe() exists to catch.)
  -- ---------------------------------------------------------
  r := record_booking_v2('ska', 'ground', v_mon, 0, 'TEST Monday', '9000000003');
  if (r->>'amount')::int <> 10000 then
    raise exception 'Monday ground priced at %, expected 10000', r->>'amount';
  end if;

  -- ---------------------------------------------------------
  -- 4. Nets: hourly, NOT forced to hour 0, flat ₹500.
  -- ---------------------------------------------------------
  r := record_booking_v2('ska', 'nets', v_sat, 18, 'TEST net', '9000000004');
  if (r->>'amount')::int <> 500 then
    raise exception 'net priced at %, expected 500', r->>'amount';
  end if;
  if (r->>'hour')::int <> 18 then
    raise exception 'net booking hour was rewritten to %, expected 18', r->>'hour';
  end if;
  if r->>'court' <> 'N1' then
    raise exception 'net landed on %, expected N1', r->>'court';
  end if;

  -- All four nets are separately sellable in the same hour.
  r := record_booking_v2('ska', 'nets', v_sat, 18, 'TEST net 2', '9000000005');
  if r->>'court' <> 'N2' then
    raise exception 'second net landed on %, expected N2', r->>'court';
  end if;

  -- ---------------------------------------------------------
  -- 5. The operator override reaches the row — this is the whole point
  --    of the migration.
  -- ---------------------------------------------------------
  r := record_booking_v2('ska', 'nets', v_mon, 7, 'TEST negotiated', '9000000006',
                         'Counter', null, 750, true, 'cash', 'Front desk');
  if (r->>'amount')::int <> 750 then
    raise exception 'override became %, expected 750', r->>'amount';
  end if;
  select * into v_row from bookings where id = r->>'id';
  if v_row.amount <> 750        then raise exception 'row amount is %', v_row.amount; end if;
  if v_row.paid_at is null      then raise exception 'paid booking has no paid_at'; end if;
  if v_row.paid_mode <> 'cash'  then raise exception 'paid_mode is %', v_row.paid_mode; end if;
  if v_row.collected_by <> 'Front desk' then raise exception 'collected_by is %', v_row.collected_by; end if;

  -- ---------------------------------------------------------
  -- 6. Book-now-pay-later, then collect at the counter.
  -- ---------------------------------------------------------
  r := record_booking_v2('ska', 'nets', v_mon, 8, 'TEST unpaid', '9000000007');
  select * into v_row from bookings where id = r->>'id';
  if v_row.paid_at is not null then raise exception 'unpaid booking was marked paid'; end if;

  r := collect_booking(r->>'id', 'upi', 'Front desk');
  select * into v_row from bookings where id = r->>'id';
  if v_row.paid_at is null     then raise exception 'collect_booking did not record payment'; end if;
  if v_row.paid_mode <> 'upi'  then raise exception 'mode is %', v_row.paid_mode; end if;

  -- Collecting twice must refuse, not silently overwrite the timestamp.
  begin
    perform collect_booking(v_row.id, 'cash', 'Someone else');
    raise exception 'a booking was collected twice';
  exception when others then
    if sqlerrm not like 'booking % was already collected%' then raise; end if;
  end;

  -- ---------------------------------------------------------
  -- 7. TENANT ISOLATION. Staff of ska must not book for demo, even
  --    though the function is SECURITY DEFINER and therefore runs
  --    outside RLS entirely.
  -- ---------------------------------------------------------
  begin
    perform record_booking_v2('demo', 'tennis', v_mon, 10, 'TEST cross tenant', '9000000008');
    raise exception 'staff of ska booked into tenant demo';
  exception when others then
    if sqlerrm <> 'not authorised' then raise; end if;
  end;

  raise notice 'all booking behaviour assertions passed';
end $$;
