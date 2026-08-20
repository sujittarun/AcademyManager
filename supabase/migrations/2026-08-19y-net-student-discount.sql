-- ============================================================
-- 2026-08-19y · a student rate for the nets, verified not claimed
-- scope: shared
--
-- SKA asked for a discount when the person booking a net is one of their
-- students. Two things had to be decided before writing a line of it.
--
-- WHO SAYS THEY ARE A STUDENT. If the page asks "are you an SKA student?"
-- and the price simply obeys the tick, then the price is whatever the
-- customer says it is, and within a week everyone ticks it. So the tick is
-- a CLAIM and the discount is a VERIFICATION: the phone number the form
-- already collects is matched against the academy's own roll, and only a
-- match is discounted. An unmatched claim is not an error and not a
-- silent refusal — the caller is told both what was claimed and what was
-- allowed, so the page can say "we could not match that number" and the
-- desk can settle it when they ring back.
--
-- WHERE THE PERCENTAGE LIVES. Not here. config.rates.studentDiscountPct,
-- read per tenant, defaulting to none — so this is one academy's
-- commercial decision expressed as data, and the next tenant who wants a
-- different number does not need a migration. It is money, so it is
-- computed in this function and nowhere else; the page prints what it is
-- handed.
--
-- NETS ONLY. The request came under "Book a net" and the ground is a
-- different kind of sale — a full-day hire, often to a company rather than
-- a family. is_full_day() already tells the two apart.
--
-- AND ONE LATENT BUG THAT MULTI-NET MAKES REACHABLE. The booking id is
--   'B-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || '-' || hour
-- which is unique only if no two bookings for the same hour are created in
-- the same millisecond. That was safe while one request meant one net. The
-- moment a customer can ask for two nets at 5pm, two inserts race for one
-- primary key, and the loser gets an error that reads like the slot is
-- full. Four random characters end it. The id is opaque everywhere —
-- nothing in any client or any function parses it — so lengthening it
-- costs nothing.
-- ============================================================

create or replace function public.request_booking(
  p_tenant text,
  p_sport text,
  p_date date,
  p_hour integer,
  p_name text,
  p_phone text,
  p_is_student boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cfg jsonb; v_courts int; v_taken int; v_amt int; v_id text;
  v_phone text; v_pending_phone int; v_pending_day int;
  v_full boolean; v_hour int;
  v_pct numeric; v_student boolean := false; v_gross int;
begin
  select config into v_cfg from tenants where id = p_tenant;
  if v_cfg is null then raise exception 'unknown academy'; end if;

  v_full := is_full_day(p_tenant, p_sport);
  v_hour := case when v_full then 0 else p_hour end;

  if not v_full and (p_hour < 6 or p_hour > 22) then raise exception 'invalid hour'; end if;
  if p_date < current_date then raise exception 'date in the past'; end if;
  if p_date > current_date + 90 then raise exception 'date too far ahead'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name required'; end if;
  v_phone := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  v_phone := right(v_phone, 10);

  delete from bookings
    where tenant_id = p_tenant and date = p_date and source = 'Website'
      and status = 'pending' and created_at < now() - interval '90 minutes';

  select count(*) into v_pending_phone from bookings
    where phone = v_phone and status = 'pending' and source = 'Website';
  if v_pending_phone >= 5 then raise exception 'too many pending requests — wait for confirmation'; end if;

  v_courts := court_count(v_cfg, p_sport);
  select count(*) into v_pending_day from bookings
    where tenant_id = p_tenant and date = p_date and source = 'Website' and status = 'pending';
  if v_pending_day >= greatest(v_courts * 8, 24) then raise exception 'the desk is catching up on requests — please call to book'; end if;

  v_amt   := slot_price(p_tenant, p_sport, p_date, v_hour);
  v_gross := v_amt;

  /* The claim is checked against the roll, never taken at face value. A
     parent books for their child, so their number counts too — it is the
     one the academy already chases for fees. */
  v_pct := coalesce(nullif(v_cfg #>> '{rates,studentDiscountPct}', '')::numeric, 0);
  if p_is_student and v_pct > 0 and not v_full then
    select exists (
      select 1 from members m
       where m.tenant_id = p_tenant
         and m.status <> 'discontinued'
         and (m.phone = v_phone or m.parent_phone = v_phone)
    ) into v_student;
    if v_student then
      v_amt := round(v_gross * (1 - v_pct / 100.0));
    end if;
  end if;

  select count(*) into v_taken from bookings
    where tenant_id = p_tenant and date = p_date and hour = v_hour
      and sport = p_sport and status <> 'cancelled';
  if v_taken >= v_courts then raise exception 'slot full'; end if;

  v_id := 'B-' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || '-' || v_hour
              || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 4);
  insert into bookings (id, tenant_id, name, phone, sport, date, hour, amount, status, source)
    values (v_id, p_tenant, trim(p_name), v_phone, p_sport, p_date, v_hour, v_amt, 'pending', 'Website');

  return jsonb_build_object(
    'id', v_id, 'amount', v_amt, 'full_day', v_full,
    'list_amount',     v_gross,
    'claimed_student', coalesce(p_is_student, false),
    'student',         v_student,
    'discount_pct',    case when v_student then v_pct else 0 end);
end $function$;

/* An added argument makes a NEW function; the six-argument one would
   linger and every existing six-argument call would match both and fail
   as ambiguous. PostgREST resolves by argument name, so a client still on
   the old build keeps working against this one. */
drop function if exists public.request_booking(text, text, date, integer, text, text);

-- ------------------------------------------------------------
-- Prove it, and clean up — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare
  r jsonb; d date := current_date + 61; v_err text;
  v_ids text[] := '{}'; v_member bigint; v_pct_before jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  select config into v_pct_before from tenants where id = 'ska';

  -- no percentage configured yet -> a tick changes nothing
  r := request_booking('ska', 'astro', d, 9, 'ZZ Disc Probe', '9000000701', true);
  v_ids := v_ids || (r->>'id');
  if (r->>'student')::boolean is true then
    raise exception 'discounted with no percentage configured';
  end if;
  if (r->>'amount')::int <> (r->>'list_amount')::int then
    raise exception 'amount moved without a discount';
  end if;

  -- configure 10%, and give the probe a matching member
  update tenants set config = jsonb_set(config, '{rates,studentDiscountPct}', '10'::jsonb)
   where id = 'ska';
  insert into members (tenant_id, name, phone, status, joined)
  values ('ska', 'ZZ Disc Member', '9000000702', 'active', ist_today())
  returning id into v_member;

  -- a CLAIM that matches the roll is honoured
  r := request_booking('ska', 'astro', d, 10, 'ZZ Disc Probe', '9000000702', true);
  v_ids := v_ids || (r->>'id');
  if (r->>'student')::boolean is not true then
    raise exception 'a real student was not recognised';
  end if;
  if (r->>'amount')::int <> round((r->>'list_amount')::int * 0.9) then
    raise exception 'discount not 10%%: % from %', r->>'amount', r->>'list_amount';
  end if;

  -- a CLAIM that matches nothing is refused, and says so rather than erroring
  r := request_booking('ska', 'astro', d, 11, 'ZZ Disc Probe', '9000000703', true);
  v_ids := v_ids || (r->>'id');
  if (r->>'student')::boolean is true then
    raise exception 'an unmatched number got the student rate';
  end if;
  if (r->>'claimed_student')::boolean is not true then
    raise exception 'the claim was not reported back';
  end if;
  if (r->>'amount')::int <> (r->>'list_amount')::int then
    raise exception 'an unmatched claim still moved the price';
  end if;

  -- a real student who does NOT tick pays list price; nothing is automatic
  r := request_booking('ska', 'astro', d, 12, 'ZZ Disc Probe', '9000000702', false);
  v_ids := v_ids || (r->>'id');
  if (r->>'student')::boolean is true then
    raise exception 'discount applied without being asked for';
  end if;

  -- THE GROUND is not a net: a full-day hire keeps its price
  r := request_booking('ska', 'ground', d, 14, 'ZZ Disc Probe', '9000000702', true);
  v_ids := v_ids || (r->>'id');
  if (r->>'student')::boolean is true then
    raise exception 'the ground was discounted';
  end if;

  -- TWO NETS AT ONE HOUR, back to back: the id must not collide
  r := request_booking('ska', 'matting', d, 15, 'ZZ Disc Probe', '9000000704', false);
  v_ids := v_ids || (r->>'id');
  r := request_booking('ska', 'matting', d, 15, 'ZZ Disc Probe', '9000000704', false);
  v_ids := v_ids || (r->>'id');
  if (select count(distinct x) from unnest(v_ids) x) <> array_length(v_ids, 1) then
    raise exception 'two bookings share an id';
  end if;
  -- and the third is refused, because SKA has two matting nets
  begin
    perform request_booking('ska', 'matting', d, 15, 'ZZ Disc Probe', '9000000705', false);
    raise exception 'a third net was sold where there are two';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'slot full' then raise; end if;
  end;

  -- CLEAN UP everything this block wrote
  delete from bookings where tenant_id = 'ska' and id = any(v_ids);
  delete from members where id = v_member;
  update tenants set config = v_pct_before where id = 'ska';
  if exists (select 1 from bookings where tenant_id='ska' and name like 'ZZ %') then
    raise exception 'probe bookings survived';
  end if;
  if exists (select 1 from members where tenant_id='ska' and name like 'ZZ %') then
    raise exception 'probe member survived';
  end if;
end $$;
