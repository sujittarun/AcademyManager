-- ============================================================
-- 2026-08-19zd · each facility carries its own hours
-- scope: shared
--
-- public_quote_multi() took ONE list of hours and applied it to every
-- facility in the request. That encoded an assumption the booking page has
-- just been shown to be wrong about: that a customer wanting an astro net
-- and a matting net wants them at the SAME time.
--
-- They often cannot have them at the same time. Astro is free at 5pm and
-- matting is full; under one shared hour list the only honest thing the
-- page could do was refuse 5pm for both — so a customer who would gladly
-- take astro at 5 and matting at 6 was told there was nothing available.
--
-- So an item now carries its own hours:
--
--   [{"sport":"astro","nets":1,"hours":[17]},
--    {"sport":"matting","nets":1,"hours":[18]}]
--
-- p_hours stays as the default for an item that omits its own, which keeps
-- the single-surface call unchanged.
--
-- Replaced rather than added to: the four-argument version is a week old,
-- has exactly one caller, and leaving both would make every existing call
-- ambiguous.
-- ============================================================

create or replace function public.public_quote_multi(
  p_tenant text,
  p_date   date,
  p_items  jsonb,                       -- [{"sport":…,"nets":n,"hours":[…]}, …]
  p_hours  integer[] default null        -- default for an item without its own
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cfg      jsonb;
  v_item     jsonb;
  v_sport    text;
  v_nets     int;
  v_courts   int;
  v_default  int[];
  v_hours    int[];
  v_n        int;
  h          int;
  v_unit     int;
  v_line     bigint;
  v_total    bigint := 0;
  v_lines    jsonb := '[]'::jsonb;
  v_allhours int[] := '{}';
  v_vpa      text;
  v_payee    text;
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

  v_default := coalesce(p_hours, '{}');
  select config into v_cfg from tenants where id = p_tenant;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_sport := nullif(btrim(coalesce(v_item ->> 'sport', '')), '');
    v_nets  := coalesce((v_item ->> 'nets')::int, 0);
    if v_sport is null then raise exception 'A facility is required.'; end if;
    if v_nets < 1 then continue; end if;          -- "none of this one"

    /* Its own hours, or the shared list when it has none. */
    if v_item ? 'hours' and jsonb_typeof(v_item -> 'hours') = 'array' then
      select coalesce(array_agg(x::int), '{}') into v_hours
        from jsonb_array_elements_text(v_item -> 'hours') x;
    else
      v_hours := v_default;
    end if;

    v_n := coalesce(array_length(v_hours, 1), 0);
    if v_n > 12 then
      raise exception 'That is more hours than anyone can book at once.';
    end if;
    foreach h in array v_hours loop
      if h < 0 or h > 23 then raise exception 'That is not a real hour.'; end if;
    end loop;

    v_courts := court_count(v_cfg, v_sport);
    if v_courts < 1 then raise exception 'This academy does not offer %.', v_sport; end if;
    if v_nets > v_courts then raise exception 'There are only % of those.', v_courts; end if;

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

    v_total    := v_total + v_line;
    v_allhours := v_allhours || v_hours;
    v_lines    := v_lines || jsonb_build_object(
      'sport', v_sport,
      'nets',  v_nets,
      'hours', v_n,
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
    /* DISTINCT hours across the whole request: two surfaces at 5pm is one
       hour of the customer's evening, not two. */
    'hours',    (select count(distinct x) from unnest(v_allhours) x),
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
-- Prove it, and clean up.
-- ------------------------------------------------------------
do $$
declare q jsonb; d date := current_date + 66; v_err text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  -- 1. DIFFERENT hours per surface: astro 1h @500, matting 2h @400 = 1300
  q := public_quote_multi('ska', d,
        '[{"sport":"astro","nets":1,"hours":[17]},
          {"sport":"matting","nets":1,"hours":[18,19]}]'::jsonb);
  if (q->>'total')::int <> 1300 then
    raise exception 'per-surface hours total is %, expected 1300', q->>'total';
  end if;
  if (q->>'hours')::int <> 3 then
    raise exception 'expected 3 distinct hours, got %', q->>'hours';
  end if;

  -- 2. the SAME hour on both is one hour of the evening, not two
  q := public_quote_multi('ska', d,
        '[{"sport":"astro","nets":1,"hours":[17]},
          {"sport":"matting","nets":1,"hours":[17]}]'::jsonb);
  if (q->>'hours')::int <> 1 then
    raise exception 'same hour counted twice: %', q->>'hours';
  end if;
  if (q->>'total')::int <> 900 then
    raise exception 'total is %, expected 900', q->>'total';
  end if;

  -- 3. counts still multiply, per surface
  q := public_quote_multi('ska', d,
        '[{"sport":"astro","nets":2,"hours":[9,10]}]'::jsonb);
  if (q->>'total')::int <> 2000 then
    raise exception 'total is %, expected 2000', q->>'total';
  end if;

  -- 4. an item with no hours of its own still takes the shared list
  q := public_quote_multi('ska', d, '[{"sport":"astro","nets":1}]'::jsonb, array[9,10]);
  if (q->>'total')::int <> 1000 then
    raise exception 'shared-hours fallback broke: %', q->>'total';
  end if;

  -- 5. the guards still bite
  begin
    perform public_quote_multi('ska', d, '[{"sport":"astro","nets":9,"hours":[9]}]'::jsonb);
    raise exception 'quoted nine nets';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'There are only%' then raise; end if;
  end;
  begin
    perform public_quote_multi('ska', d, '[{"sport":"astro","nets":1,"hours":[99]}]'::jsonb);
    raise exception 'accepted hour 99';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That is not a real hour%' then raise; end if;
  end;
end $$;
