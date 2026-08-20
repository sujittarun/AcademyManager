-- ============================================================
-- 2026-08-19za · the flood cap counts nets now, so it has to allow some
-- scope: shared
--
-- request_booking() refuses a phone with five pending website requests.
-- That was sized when one request meant one net for one hour. A customer
-- who now asks for two nets across three hours makes SIX rows, and the
-- sixth is refused with "too many pending requests — wait for
-- confirmation" — a message that describes abuse to someone doing exactly
-- what the page invited them to do.
--
-- Twelve, not unlimited: three nets across four hours is a real booking
-- and about the largest honest one; beyond that the desk should be
-- involved. The per-venue-day cap is untouched and still the real defence
-- — greatest(courts * 8, 24) rows per academy per day.
--
-- AND THE CAP WAS NEVER SCOPED TO THE ACADEMY. `where phone = v_phone`
-- counts a person's pending requests at EVERY tenant on the platform, so
-- somebody with four pending nets at Leo arrives at Super Kings with one
-- request left. Nobody has hit it — Leo and SKA share no customers today —
-- but it is the same fault 2026-08-17d fixed in submit_application, where
-- a busy academy throttled a quiet one's admissions. Same fix here.
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

  /* SCOPED TO THE TENANT, and sized for a booking of several nets. */
  select count(*) into v_pending_phone from bookings
    where tenant_id = p_tenant and phone = v_phone
      and status = 'pending' and source = 'Website';
  if v_pending_phone >= 12 then raise exception 'too many pending requests — wait for confirmation'; end if;

  v_courts := court_count(v_cfg, p_sport);
  select count(*) into v_pending_day from bookings
    where tenant_id = p_tenant and date = p_date and source = 'Website' and status = 'pending';
  if v_pending_day >= greatest(v_courts * 8, 24) then raise exception 'the desk is catching up on requests — please call to book'; end if;

  v_amt   := slot_price(p_tenant, p_sport, p_date, v_hour);
  v_gross := v_amt;

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

-- ------------------------------------------------------------
-- Prove it, and clean up.
-- ------------------------------------------------------------
do $$
declare d date := current_date + 62; v_ids text[] := '{}'; r jsonb; i int; v_err text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  /* Six rows from one number — two nets across three hours — is the exact
     shape that used to be refused on the sixth. */
  for i in 9..11 loop
    r := request_booking('ska','astro',d,i,'ZZ Cap Probe','9000000901'); v_ids := v_ids || (r->>'id');
    r := request_booking('ska','astro',d,i,'ZZ Cap Probe','9000000901'); v_ids := v_ids || (r->>'id');
  end loop;
  if array_length(v_ids,1) <> 6 then
    raise exception 'expected 6 bookings, got %', array_length(v_ids,1);
  end if;

  /* Twelve is still a ceiling. Astro has 2 nets, so hours 12..14 add six
     more and the thirteenth request is refused on the cap. */
  for i in 12..14 loop
    r := request_booking('ska','astro',d,i,'ZZ Cap Probe','9000000901'); v_ids := v_ids || (r->>'id');
    r := request_booking('ska','astro',d,i,'ZZ Cap Probe','9000000901'); v_ids := v_ids || (r->>'id');
  end loop;
  begin
    perform request_booking('ska','astro',d,15,'ZZ Cap Probe','9000000901');
    raise exception 'the cap never bit';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'too many pending%' then raise; end if;
  end;

  /* And it is this academy's cap, not the platform's: the same number is
     free to ask Leo. */
  begin
    r := request_booking('leo','badminton',d,9,'ZZ Cap Probe','9000000901');
    v_ids := v_ids || (r->>'id');
    delete from bookings where tenant_id='leo' and id = r->>'id';
  exception when others then
    get stacked diagnostics v_err = message_text;
    /* Leo may not run that facility; only a CAP error would be the bug. */
    if v_err like 'too many pending%' then
      raise exception 'one academy''s pending requests still throttle another';
    end if;
  end;

  delete from bookings where tenant_id in ('ska','leo') and id = any(v_ids);
  if exists (select 1 from bookings where name like 'ZZ Cap Probe%') then
    raise exception 'probe bookings survived';
  end if;
end $$;
