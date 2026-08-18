-- ============================================================
-- 2026-08-18h · tenant_revenue_streams() stops being blind to four of the
--               six academies
-- scope: shared
--
-- THE BUG
-- The function reported court revenue like this:
--
--     ... from bookings b where b.sport = 'tennis'
--     ... from bookings b where b.sport = 'pickleball'
--
-- Two sports, hard-coded, from whichever tenant it was first written for.
-- Every other academy's rentals were invisible. Super Kings sells `astro`,
-- `matting` and `ground`; asked for August it returned tennis 0,
-- pickleball 0 while the academy had actually taken ₹25,900. Not an error,
-- not a warning — two zeroes and a confident-looking chart.
--
-- THE FIX, AND WHY IT DOES NOT BREAK THE FOUR APPS THAT CALL IT
-- Leo, the demo, Machaxi and MatchPoint all render `tennis`,
-- `pickleball` and `memberships` by name. Renaming or dropping those keys
-- breaks four live clients that cannot be updated together, so they stay
-- exactly as they are and keep meaning exactly what they meant.
--
-- What is ADDED is a `courts` array: one entry per facility the academy
-- actually has, taken from tenants.config.courts, so the answer follows
-- the tenant instead of a guess made once. A client that knows about
-- `courts` gets the truth; one that does not is no worse off than today.
--
-- `total_courts` is there so a caller can show one honest number without
-- having to sum an array it may not understand.
-- ============================================================

create or replace function public.tenant_revenue_streams(p_tenant text, p_months integer default 6)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_cfg jsonb;
begin
  if not (auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;

  select config into v_cfg from tenants where id = p_tenant;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'm',            to_char(mo, 'Mon'),
        'memberships',  memberships,
        -- KEPT, BYTE FOR BYTE. Four live apps read these two by name.
        'tennis',       tennis,
        'pickleball',   pickleball,
        -- ADDED: what this academy actually sells.
        'courts',       courts,
        'total_courts', total_courts
      ) order by mo), '[]'::jsonb)
    from (
      select mo,
        (select coalesce(sum(amount), 0) from payments p
          where p.tenant_id = p_tenant and p.type = 'Membership'
            and date_trunc('month', p.on_date) = mo) as memberships,
        (select coalesce(sum(amount), 0) from bookings b
          where b.tenant_id = p_tenant and b.status = 'confirmed' and b.sport = 'tennis'
            and date_trunc('month', b.date) = mo) as tennis,
        (select coalesce(sum(amount), 0) from bookings b
          where b.tenant_id = p_tenant and b.status = 'confirmed' and b.sport = 'pickleball'
            and date_trunc('month', b.date) = mo) as pickleball,
        /* One row per facility in config.courts, in a stable order so a
           chart's colours do not shuffle between months. A facility with
           no bookings still appears, at 0 — "we sell this and took
           nothing" is a different and more useful fact than silence. */
        (select coalesce(jsonb_agg(
                  jsonb_build_object('sport', k, 'amount', amt) order by k), '[]'::jsonb)
           from (
             select k,
                    (select coalesce(sum(b.amount), 0) from bookings b
                      where b.tenant_id = p_tenant and b.status = 'confirmed'
                        and b.sport = k and date_trunc('month', b.date) = mo) as amt
               from jsonb_object_keys(coalesce(v_cfg->'courts', '{}'::jsonb)) as k
           ) per_sport
        ) as courts,
        /* Every confirmed rental that month, whatever the facility — this
           does not depend on config being complete, so it stays right even
           if a facility is sold before it is configured. */
        (select coalesce(sum(b.amount), 0) from bookings b
          where b.tenant_id = p_tenant and b.status = 'confirmed'
            and date_trunc('month', b.date) = mo) as total_courts
      from generate_series(
             date_trunc('month', current_date) - ((p_months - 1) || ' months')::interval,
             date_trunc('month', current_date), '1 month') mo
    ) x
  );
end
$function$;

-- ------------------------------------------------------------
-- Prove it. Reads only.
-- ------------------------------------------------------------
do $$
declare r jsonb; aug jsonb; i int; found boolean := false;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"operator"}}', true);

  -- SUPER KINGS: was two zeroes, must now report its real facilities.
  r := tenant_revenue_streams('ska', 2);
  aug := r -> (jsonb_array_length(r) - 1);          -- the current month

  if (aug->>'total_courts')::numeric <= 0 then
    raise exception 'ska total_courts is %, expected the month''s real rentals', aug->>'total_courts';
  end if;

  -- astro, matting and ground must each be named, even at zero.
  for i in 0 .. jsonb_array_length(aug->'courts') - 1 loop
    if (aug->'courts'->i->>'sport') = 'ground' then found := true; end if;
  end loop;
  if not found then
    raise exception 'ska courts array does not mention the ground: %', aug->'courts';
  end if;
  if jsonb_array_length(aug->'courts') <> 3 then
    raise exception 'ska should report 3 facilities, got %', jsonb_array_length(aug->'courts');
  end if;

  -- THE REGRESSION THAT MATTERS: the four apps reading these keys by name.
  if aug->'tennis' is null or aug->'pickleball' is null or aug->'memberships' is null then
    raise exception 'a key four live clients render by name went missing';
  end if;

  -- And a tenant that genuinely sells tennis must still report it there.
  r := tenant_revenue_streams('demo', 2);
  aug := r -> (jsonb_array_length(r) - 1);
  if aug->'tennis' is null then
    raise exception 'demo lost its tennis key';
  end if;

  -- A staff member of one academy must not read another's takings.
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  begin
    perform tenant_revenue_streams('demo', 1);
    raise exception 'staff of ska read demo revenue';
  exception when others then
    if sqlerrm <> 'not authorised' then raise; end if;
  end;
end $$;
