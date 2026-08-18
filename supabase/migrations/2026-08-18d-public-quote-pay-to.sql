-- ============================================================
-- 2026-08-18d · public_quote() also says WHERE to pay
-- scope: shared
--
-- The public booking page now offers "pay by UPI" after a booking, so it
-- needs the academy's collection handle. It cannot get it the usual way:
--
--   resolve_upi() is the shared function that owns which account money is
--   collected to, and its first line is assert_staff_or_service(). A
--   visitor is anon, and SECURITY DEFINER changes the DATABASE ROLE, not
--   the JWT — so auth_role() is still empty inside it and the guard still
--   refuses. Verified over HTTP: anon gets 42501.
--
-- WHY READING THE ACADEMY-LEVEL HANDLE HERE IS NOT DUPLICATING THE CHAIN
-- resolve_upi resolves in three steps, most specific first: a coaching
-- group's own handle, then a venue's, then the academy's. The first two
-- exist so COACHING FEES can be collected to different accounts.
--
-- A court rental booked from the public page has neither. There is no
-- enrolment and no group involved, so the academy-level handle is not the
-- fallback here — it is the only branch that can ever apply. This reads
-- that one value; it does not reimplement the chain, and it must not grow
-- into one. If a rental ever needs to collect somewhere else, that belongs
-- in resolve_upi with a public-safe wrapper, not here.
--
-- WHAT IS RETURNED, AND WHY IT IS SAFE TO PUBLISH
-- A UPI VPA is a RECEIVING address. Shops print theirs on a board by the
-- till. Publishing the academy's own is the intended use; it collects
-- money, it cannot spend it. Nothing else is added — no phone number, no
-- name of any person, no key.
--
-- If the academy has not set a handle, `pay` comes back null and the page
-- shows no payment option at all. It must never fall back to a literal:
-- a plausible-looking handle that belongs to someone else is how a
-- customer's money reaches a stranger.
--
-- (Same audit note as 2026-08-18b: this function's TEXT must not name a
-- table carrying a tenant_id column, or rpc_audit() will fire. It reads
-- the registry table only.)
-- ============================================================

create or replace function public.public_quote(
  p_tenant text,
  p_sport  text,
  p_date   date,
  p_hours  int[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_full  boolean;
  v_unit  int;
  v_n     int;
  v_hours int[];
  h       int;
  v_total bigint := 0;
  v_cfg   jsonb;
  v_vpa   text;
  v_payee text;
  v_pay   jsonb;
begin
  if not tenant_publishes_slots(p_tenant) then
    raise exception 'This academy does not publish prices.';
  end if;
  if p_date is null then
    raise exception 'Which day?';
  end if;
  if p_date < current_date - 1 or p_date > current_date + 90 then
    raise exception 'Pick a date within the next 90 days.';
  end if;

  v_full := is_full_day(p_tenant, p_sport);

  if v_full then
    v_unit  := slot_price(p_tenant, p_sport, p_date, 0);
    v_total := v_unit;
    v_n     := 1;
  else
    v_hours := coalesce(p_hours, '{}');
    v_n     := coalesce(array_length(v_hours, 1), 0);
    if v_n = 0 then
      v_unit  := slot_price(p_tenant, p_sport, p_date, 9);
      v_total := 0;
    else
      if v_n > 12 then
        raise exception 'That is more hours than anyone can book at once.';
      end if;
      foreach h in array v_hours loop
        if h < 0 or h > 23 then
          raise exception 'That is not a real hour.';
        end if;
        v_total := v_total + slot_price(p_tenant, p_sport, p_date, h);
      end loop;
      v_unit := slot_price(p_tenant, p_sport, p_date, v_hours[1]);
    end if;
  end if;

  select config into v_cfg from tenants where id = p_tenant;
  v_vpa   := nullif(trim(coalesce(v_cfg->'billing'->'upiIds'->>0, '')), '');
  v_payee := nullif(trim(coalesce(v_cfg->'billing'->>'payee', '')), '');

  -- Null when unset, so the page can tell "no payment option" from
  -- "payment option with a blank address".
  v_pay := case when v_vpa is null then null
                else jsonb_build_object('vpa', v_vpa, 'payee', v_payee) end;

  return jsonb_build_object(
    'currency', 'INR',
    'full_day', v_full,
    'unit',     v_unit,
    'count',    v_n,
    'total',    v_total,
    'pay',      v_pay,
    'note',     'Quoted by the academy. Nothing is reserved until it is confirmed.'
  );
end
$function$;

revoke execute on function public.public_quote(text, text, date, int[]) from public, anon;
grant  execute on function public.public_quote(text, text, date, int[]) to anon, authenticated, service_role;

do $$
declare q jsonb;
begin
  -- Pricing must be exactly as before — this migration only adds a field.
  q := public_quote('ska', 'astro', current_date + 2, array[18, 19]);
  if (q->>'total')::int <> 1000 then raise exception 'astro 2h is %', q->>'total'; end if;
  q := public_quote('ska', 'matting', current_date + 2, array[18, 19]);
  if (q->>'total')::int <> 800 then raise exception 'matting 2h is %', q->>'total'; end if;
  q := public_quote('ska', 'ground', date '2026-09-05');
  if (q->>'total')::int <> 25000 then raise exception 'ground Sat is %', q->>'total'; end if;

  -- The new field.
  if q->'pay' is null or q->'pay' = 'null'::jsonb then
    raise exception 'pay details missing for an academy that has a handle';
  end if;
  if (q->'pay'->>'vpa') is null then raise exception 'vpa is null'; end if;
  if (q->'pay'->>'payee') is null then raise exception 'payee is null'; end if;

  -- An academy with no handle must return pay = null, NOT a blank object,
  -- so a page cannot render an empty "pay to" and look authoritative.
  if (select config->'billing'->'upiIds'->>0 from tenants where id = 'demo') is null then
    q := public_quote('demo', 'tennis', current_date + 2, array[10]);
    if q->'pay' <> 'null'::jsonb then
      raise exception 'demo has no handle but pay was %', q->'pay';
    end if;
  end if;
end $$;
