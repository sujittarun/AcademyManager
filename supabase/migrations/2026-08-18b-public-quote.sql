-- ============================================================
-- 2026-08-18b · public_quote() — tell a visitor what it costs BEFORE
--               they commit, without moving money into JavaScript
-- scope: shared
--
-- THE PROBLEM
-- The public page could only show a price AFTER submitting, because the
-- amount came back on the write. Everything that prices a slot is revoked
-- from anon, correctly: those functions take a tenant argument, so a
-- public grant would hand every academy's rate card to the public key.
--
-- So the page had two bad options and took neither:
--   · print the tariff as a literal in the client — the house rule exists
--     to stop exactly that, and a rate that drifts from config quotes a
--     price the database will never charge;
--   · say nothing until after the request — which is what it did, and is
--     a poor thing to ask of someone about to hand over their phone number.
--
-- THE SHAPE OF THE FIX
-- One narrow, deliberately public read that computes the figure in SQL and
-- returns nothing else. It is the fourth kind of thing an anonymous
-- visitor may ask this database, alongside "does this academy exist",
-- "what is free" and "here is my enquiry".
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   · no name, no phone, no identity of any kind, in or out;
--   · no reservation — quoting is not holding, and the wording the page
--     shows says so;
--   · nothing for an academy that has not opted into publishing, checked
--     through the same helper the public availability view uses.
--
-- WHY IT DOES NOT SHOW UP IN rpc_audit()
-- That audit flags any SECURITY DEFINER function anon may execute whose
-- TEXT mentions a table carrying a tenant_id column. This one reads the
-- registry table only, which is keyed on `id` and has no such column — so
-- it is outside the audit's definition of tenant data rather than being
-- excused from it. Keep it that way: naming a tenant-scoped table here,
-- even in a comment, would make the audit fire, and the audit firing is
-- how this platform finds leaks.
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
begin
  if not tenant_publishes_slots(p_tenant) then
    raise exception 'This academy does not publish prices.';
  end if;
  if p_date is null then
    raise exception 'Which day?';
  end if;
  -- A quote is for now, not for archaeology, and not for a year out.
  if p_date < current_date - 1 or p_date > current_date + 90 then
    raise exception 'Pick a date within the next 90 days.';
  end if;

  v_full := is_full_day(p_tenant, p_sport);

  if v_full then
    -- Sold by the day; the hour is always 0 and any hours sent are noise.
    v_unit  := slot_price(p_tenant, p_sport, p_date, 0);
    v_total := v_unit;
    v_n     := 1;
  else
    v_hours := coalesce(p_hours, '{}');
    v_n     := coalesce(array_length(v_hours, 1), 0);
    if v_n = 0 then
      -- No hours chosen yet: quote the unit so the page can say "from X".
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

  return jsonb_build_object(
    'currency', 'INR',
    'full_day', v_full,
    'unit',     v_unit,
    'count',    v_n,
    'total',    v_total,
    -- Said here so the page does not have to invent the caveat, and so
    -- every client says the same thing.
    'note',     'Quoted by the academy. Nothing is reserved until it is confirmed.'
  );
end
$function$;

-- Public BY DESIGN, like the other three an anonymous visitor may call.
-- Default-closed first: the grant CREATE hands to PUBLIC is the one that
-- matters, and revoking `anon` alone would change nothing.
revoke execute on function public.public_quote(text, text, date, int[]) from public, anon;
grant  execute on function public.public_quote(text, text, date, int[]) to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it. Reads only — nothing to clean up.
-- ------------------------------------------------------------
do $$
declare q jsonb; v_sat date := date '2026-09-05'; v_mon date := date '2026-09-07';
begin
  if extract(isodow from v_sat) <> 6 then raise exception 'fixture is not a Saturday'; end if;

  -- Full-day ground: the weekday ladder, straight out of config.
  q := public_quote('ska', 'ground', v_sat);
  if (q->>'total')::int <> 25000 then raise exception 'Sat ground quoted %', q->>'total'; end if;
  if not (q->>'full_day')::boolean then raise exception 'ground should be full_day'; end if;

  q := public_quote('ska', 'ground', v_mon);
  if (q->>'total')::int <> 10000 then raise exception 'Mon ground quoted %', q->>'total'; end if;

  -- Nets: the total is the SUM the database worked out, not the client.
  q := public_quote('ska', 'nets', v_sat, array[18, 19, 20]);
  if (q->>'total')::int <> 1500 then raise exception '3 nets hours quoted %', q->>'total'; end if;
  if (q->>'count')::int <> 3 then raise exception 'count is %', q->>'count'; end if;
  if (q->>'unit')::int <> 500 then raise exception 'unit is %', q->>'unit'; end if;

  -- No hours yet: a unit to say "from", and no total to mislead.
  q := public_quote('ska', 'nets', v_sat);
  if (q->>'total')::int <> 0 then raise exception 'empty selection has a total'; end if;
  if (q->>'unit')::int <> 500 then raise exception 'empty selection has no unit'; end if;

  -- Refusals.
  begin
    perform public_quote('ska', 'nets', v_sat, array[1,2,3,4,5,6,7,8,9,10,11,12,13]);
    raise exception 'accepted 13 hours';
  exception when others then
    if sqlerrm not like 'That is more hours%' then raise; end if;
  end;

  begin
    perform public_quote('ska', 'nets', current_date + 200);
    raise exception 'accepted a date 200 days out';
  exception when others then
    if sqlerrm not like 'Pick a date%' then raise; end if;
  end;

  -- An academy that does not publish must not be quotable.
  begin
    perform public_quote('mpp', 'badminton', v_mon);
    raise exception 'quoted an academy that does not publish';
  exception when others then
    if sqlerrm not like 'This academy does not publish%'
       and sqlerrm not like 'unknown sport%' then raise; end if;
  end;
end $$;
