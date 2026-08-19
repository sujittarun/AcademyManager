-- ============================================================
-- 2026-08-19g · a ground enquiry is a BOOKING, not an admission
-- scope: shared
--
-- WHAT WAS HAPPENING
-- booking.html could not request the ground through request_booking(),
-- because the very first line of that function is
--
--     if p_hour < 6 or p_hour > 22 then raise exception 'invalid hour';
--
-- and a full-day booking is hour 0 — the sentinel 2026-08-17c chose so the
-- existing unique index on (tenant_id, date, hour, court) stops the ground
-- being sold twice. So the page worked around it by calling
-- submit_application() instead, filing the rental as an ADMISSION with
-- "Main ground — full day rental" in the sport column.
--
-- WHY THAT MATTERS MORE THAN IT LOOKS
-- A ground renter then arrives in the admissions inbox next to families
-- joining the academy, with no consent, no date of birth and no parent —
-- because a person hiring a field for a day has none of those. The owner
-- reported exactly that: "submitted without consent or details", and an
-- edit form full of blanks.
--
-- And approving one would have created a MEMBER and an ENROLMENT: a
-- cricket student who never enrolled, landing on the roster, in every
-- register, and in the fee chase. Nobody had approved one yet.
--
-- It also meant the enquiry did NOT hold the day. submit_application
-- writes no booking, so public_slots never saw it and two people could ask
-- for the same ground on the same date.
--
-- THE FIX
-- request_booking() learns what record_booking_v2() already knows: a
-- facility with a `daily` rate block is sold by the DAY, so the hour is
-- forced to 0 and the 6–22 check does not apply to it. Same helper
-- (is_full_day), same sentinel, same index doing the work.
--
-- Taken VERBATIM from the live definition with the hour handling changed
-- and the price sourced from slot_price (which knows the weekday) instead
-- of slot_rate (which does not). Everything else — the rate limits, the
-- self-cleaning sweep, the capacity check — is untouched.
-- ============================================================

create or replace function public.request_booking(p_tenant text, p_sport text, p_date date, p_hour integer, p_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cfg jsonb; v_courts int; v_taken int; v_amt int; v_id text;
  v_phone text; v_pending_phone int; v_pending_day int;
  v_full boolean; v_hour int;
begin
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;

  /* A full-day facility is sold by the day, so its hour is the 0 sentinel
     and the opening-hours check is meaningless for it. Decided by the
     SERVER from config, never by what the caller sent — if the client were
     trusted to send 0, someone passing 14 would miss the unique index and
     the ground would be sold twice. */
  v_full := is_full_day(p_tenant, p_sport);
  v_hour := case when v_full then 0 else p_hour end;

  if not v_full and (p_hour < 6 or p_hour > 22) then raise exception 'invalid hour'; end if;
  if p_date < current_date then raise exception 'date in the past'; end if;
  if p_date > current_date + 90 then raise exception 'date too far ahead'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name required'; end if;
  -- require a real 10-digit phone: gives us an identity to rate-limit on
  v_phone := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  v_phone := right(v_phone, 10);

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

  /* slot_price, not slot_rate: the ground costs a different amount on a
     Friday than on a Tuesday, and slot_rate takes no date so it cannot
     know. It delegates to slot_rate for every facility without a `daily`
     block, so the nets are priced exactly as before. */
  v_amt := slot_price(p_tenant, p_sport, p_date, v_hour);

  select count(*) into v_taken from bookings
    where tenant_id = p_tenant and date = p_date and hour = v_hour
      and sport = p_sport and status <> 'cancelled';
  if v_taken >= v_courts then raise exception 'slot full'; end if;

  v_id := 'B-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || '-' || v_hour;
  insert into bookings (id, tenant_id, name, phone, sport, date, hour, amount, status, source)
    values (v_id, p_tenant, trim(p_name), v_phone, p_sport, p_date, v_hour, v_amt, 'pending', 'Website');
  return jsonb_build_object('id', v_id, 'amount', v_amt, 'full_day', v_full);
end $function$;

-- ------------------------------------------------------------
-- Prove it, and CLEAN UP — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare r jsonb; v_err text; d date := current_date + 60;   -- far from any real booking
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  -- THE GROUND: any hour sent, hour 0 stored, priced for that weekday
  r := request_booking('ska', 'ground', d, 14, 'ZZ Ground Req', '9000000601');
  if (r->>'full_day')::boolean is not true then
    raise exception 'ground was not treated as full day';
  end if;
  if (select hour from bookings where id = r->>'id') <> 0 then
    raise exception 'ground stored at hour %, expected 0',
      (select hour from bookings where id = r->>'id');
  end if;
  if (r->>'amount')::int <= 0 then
    raise exception 'ground priced at %', r->>'amount';
  end if;

  -- and it now HOLDS the day: a second request is refused
  begin
    perform request_booking('ska', 'ground', d, 9, 'ZZ Ground Req 2', '9000000602');
    raise exception 'the ground was requested twice for one day';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'slot full' then raise; end if;
  end;

  delete from bookings where tenant_id='ska' and id = r->>'id';

  -- THE NETS are unchanged: still hour-bound, still refused outside 6..22
  begin
    perform request_booking('ska', 'astro', d, 3, 'ZZ Net Req', '9000000603');
    raise exception 'a net was accepted at 3am';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'invalid hour' then raise; end if;
  end;

  r := request_booking('ska', 'astro', d, 9, 'ZZ Net Req', '9000000603');
  if (select hour from bookings where id = r->>'id') <> 9 then
    raise exception 'a net did not keep its hour';
  end if;
  delete from bookings where tenant_id='ska' and id = r->>'id';

  if exists (select 1 from bookings where tenant_id='ska' and name like 'ZZ %') then
    raise exception 'probe bookings survived';
  end if;
end $$;
