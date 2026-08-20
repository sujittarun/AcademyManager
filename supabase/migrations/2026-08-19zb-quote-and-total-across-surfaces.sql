-- ============================================================
-- 2026-08-19zb · a total, computed where totals belong
-- scope: shared
--
-- Booking one astro net and one matting net in a single request left the
-- page with two figures and no way to add them, because adding them is
-- exactly what a client on this platform must not do. So it printed two
-- lines and a sentence apologising for the missing total, and offered no
-- payment at all — which is a worse answer than either.
--
-- The rule was never "do not show a total". It is "do not COMPUTE one".
-- Two functions, both anon-callable because the people using them are
-- anonymous:
--
--   public_quote_multi()  — what a mixed selection would cost, BEFORE
--                           anything is booked. Per-surface lines and a
--                           grand total, all summed in SQL from
--                           slot_price(), the same function every other
--                           price on this platform comes from.
--
--   public_booking_total() — what was ACTUALLY charged, after the rows
--                           exist. Needed separately because the quote
--                           cannot know about the student rate: that is
--                           applied by request_booking() against the
--                           academy's roll, and only the stored rows carry
--                           the real figure.
--
-- WHY THE QUOTE DOES NOT KNOW ABOUT THE DISCOUNT, deliberately. Quoting a
-- discounted price would mean checking a typed phone against the member
-- list before anything is booked — which turns the quote box into an
-- oracle for "is this number one of your students?", answerable by anyone
-- with the public key. The list price is quoted; the confirmation shows
-- what was charged.
--
-- AND public_booking_total() TAKES THE PHONE. Booking ids are handed to
-- the person who just made them, but they are still guessable in principle,
-- and a sum is a small leak that costs nothing to close: rows are counted
-- only when the phone matches the one on them.
-- ============================================================

create or replace function public.public_quote_multi(
  p_tenant text,
  p_date   date,
  p_items  jsonb,                       -- [{"sport":"astro","nets":2}, …]
  p_hours  integer[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cfg    jsonb;
  v_item   jsonb;
  v_sport  text;
  v_nets   int;
  v_courts int;
  v_hours  int[];
  v_n      int;
  h        int;
  v_unit   int;
  v_line   bigint;
  v_total  bigint := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_vpa    text;
  v_payee  text;
begin
  if not tenant_publishes_slots(p_tenant) then
    raise exception 'This academy does not publish prices.';
  end if;
  if p_date is null then raise exception 'Which day?'; end if;
  if p_date < current_date - 1 or p_date > current_date + 90 then
    raise exception 'Pick a date within the next 90 days.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Nothing was asked for.';
  end if;
  if jsonb_array_length(p_items) > 4 then
    raise exception 'That is more facilities than can be booked at once.';
  end if;

  v_hours := coalesce(p_hours, '{}');
  v_n     := coalesce(array_length(v_hours, 1), 0);
  if v_n > 12 then
    raise exception 'That is more hours than anyone can book at once.';
  end if;
  foreach h in array v_hours loop
    if h < 0 or h > 23 then raise exception 'That is not a real hour.'; end if;
  end loop;

  select config into v_cfg from tenants where id = p_tenant;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_sport := nullif(btrim(coalesce(v_item ->> 'sport', '')), '');
    v_nets  := coalesce((v_item ->> 'nets')::int, 0);
    if v_sport is null then raise exception 'A facility is required.'; end if;
    if v_nets < 1 then continue; end if;          -- "none of this one"

    /* Never quote for more nets than the academy owns — a price for three
       when there are two is a number nobody can honour. */
    v_courts := court_count(v_cfg, v_sport);
    if v_courts < 1 then raise exception 'This academy does not offer %.', v_sport; end if;
    if v_nets > v_courts then
      raise exception 'There are only % of those.', v_courts;
    end if;

    /* A full-day facility is priced by the day; everything else by the
       hours chosen. slot_price() knows which, and knows the weekday. */
    if is_full_day(p_tenant, v_sport) then
      v_unit := slot_price(p_tenant, v_sport, p_date, 0);
      v_line := v_unit::bigint * v_nets;
    else
      v_unit := slot_price(p_tenant, v_sport, p_date,
                           case when v_n > 0 then v_hours[1] else 9 end);
      v_line := 0;
      foreach h in array v_hours loop
        v_line := v_line + slot_price(p_tenant, v_sport, p_date, h);
      end loop;
      v_line := v_line * v_nets;
    end if;

    v_total := v_total + v_line;
    v_lines := v_lines || jsonb_build_object(
      'sport', v_sport,
      'nets',  v_nets,
      'unit',  v_unit,
      'each',  case when v_nets > 0 then (v_line / v_nets) else 0 end,
      'total', v_line);
  end loop;

  if jsonb_array_length(v_lines) = 0 then
    raise exception 'Nothing was asked for.';
  end if;

  v_vpa   := nullif(trim(coalesce(v_cfg->'billing'->'upiIds'->>0, '')), '');
  v_payee := nullif(trim(coalesce(v_cfg->'billing'->>'payee', '')), '');

  return jsonb_build_object(
    'currency', 'INR',
    'hours',    v_n,
    'lines',    v_lines,
    'total',    v_total,
    'pay',      case when v_vpa is null then null
                     else jsonb_build_object('vpa', v_vpa, 'payee', v_payee) end);
end
$function$;

revoke execute on function public.public_quote_multi(text, date, jsonb, integer[]) from public;
grant  execute on function public.public_quote_multi(text, date, jsonb, integer[])
  to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- What was actually charged, once the rows exist.
-- ------------------------------------------------------------
create or replace function public.public_booking_total(
  p_tenant text,
  p_ids    text[],
  p_phone  text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_phone text; v_total bigint; v_n int; v_disc int;
begin
  if not tenant_publishes_slots(p_tenant) then
    raise exception 'This academy does not publish prices.';
  end if;
  v_phone := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 10);
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  if p_ids is null or array_length(p_ids, 1) is null then
    raise exception 'Nothing to total.';
  end if;
  if array_length(p_ids, 1) > 48 then
    raise exception 'Too many bookings at once.';
  end if;

  /* THE PHONE IS THE KEY. Without it this would total any booking whose id
     somebody could guess. With it, a caller can only add up rows they
     already made. */
  select coalesce(sum(amount), 0), count(*)
    into v_total, v_n
    from bookings
   where tenant_id = p_tenant
     and id = any(p_ids)
     and phone = v_phone
     and status <> 'cancelled';

  return jsonb_build_object('currency', 'INR', 'count', v_n, 'total', v_total);
end
$function$;

revoke execute on function public.public_booking_total(text, text[], text) from public;
grant  execute on function public.public_booking_total(text, text[], text)
  to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and clean up.
-- ------------------------------------------------------------
do $$
declare q jsonb; t jsonb; d date := current_date + 65; ids text[] := '{}'; r jsonb; v_err text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  -- 1. one of each, two hours: astro 2x500 + matting 2x400 = 1800
  q := public_quote_multi('ska', d,
        '[{"sport":"astro","nets":1},{"sport":"matting","nets":1}]'::jsonb,
        array[9,10]);
  if (q->>'total')::int <> 1800 then
    raise exception 'mixed total is %, expected 1800', q->>'total';
  end if;
  if jsonb_array_length(q->'lines') <> 2 then
    raise exception 'expected two lines, got %', jsonb_array_length(q->'lines');
  end if;

  -- 2. the count multiplies: 2 astro + 1 matting over 2 hours = 2800
  q := public_quote_multi('ska', d,
        '[{"sport":"astro","nets":2},{"sport":"matting","nets":1}]'::jsonb,
        array[9,10]);
  if (q->>'total')::int <> 2800 then
    raise exception 'total is %, expected 2800', q->>'total';
  end if;

  -- 3. "none of this one" is skipped, not priced
  q := public_quote_multi('ska', d,
        '[{"sport":"astro","nets":1},{"sport":"matting","nets":0}]'::jsonb, array[9]);
  if jsonb_array_length(q->'lines') <> 1 or (q->>'total')::int <> 500 then
    raise exception 'a zero line was priced: %', q;
  end if;

  -- 4. more nets than exist is refused
  begin
    perform public_quote_multi('ska', d, '[{"sport":"astro","nets":5}]'::jsonb, array[9]);
    raise exception 'quoted five nets where there are two';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'There are only%' then raise; end if;
  end;

  -- 5. the real total, from the rows themselves
  r := request_booking('ska','astro',d,11,'ZZ Total Probe','9000000941');  ids := ids || (r->>'id');
  r := request_booking('ska','matting',d,11,'ZZ Total Probe','9000000941'); ids := ids || (r->>'id');
  t := public_booking_total('ska', ids, '9000000941');
  if (t->>'count')::int <> 2 or (t->>'total')::int <> 900 then
    raise exception 'booking total is %, expected 900 over 2', t;
  end if;

  -- 6. and somebody else's phone totals nothing
  t := public_booking_total('ska', ids, '9000000942');
  if (t->>'count')::int <> 0 or (t->>'total')::int <> 0 then
    raise exception 'a stranger totalled another persons bookings: %', t;
  end if;

  /* Scoped to THIS block's own probe. A broad 'ZZ %' check trips over
     anybody else's leftovers and fails a migration that had nothing to do
     with them — which is exactly what happened the first time this ran,
     over four stray rows left by a browser test. Useful signal, wrong
     place for it. */
  delete from bookings where tenant_id='ska' and id = any(ids);
  if exists (select 1 from bookings where tenant_id='ska' and name = 'ZZ Total Probe') then
    raise exception 'probe bookings survived';
  end if;
end $$;
