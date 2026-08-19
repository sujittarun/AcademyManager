-- ============================================================
-- 2026-08-19e · tenant_activity() — is the client actually using it?
-- scope: shared
--
-- tenant_health() already answers "yes or no" (events_30d, active_days_30d,
-- last_event_at). This answers the next three questions an operator asks
-- the moment a tenant is handed a live link:
--
--     is anyone opening it, and on which days
--     what are they actually doing in it
--     on what device — because a layout tested on a laptop and used on a
--       phone is the commonest way a handover goes quiet
--
-- COUNTS ONLY. No names, no phone numbers, no session contents. The device
-- fields are the buckets cloud.js records (phone/tablet/desktop, browser
-- family, a viewport RANGE) precisely so this can never become a way to
-- pick a person out.
--
-- WHY A FUNCTION RATHER THAN THE CONSOLE QUERYING events DIRECTLY
-- `events` has an anon INSERT policy and no tenant filter on read that the
-- console could rely on. Routing through a definer function with an
-- explicit guard means one place decides who may see a tenant's usage, and
-- rpc_audit() keeps watching it.
-- ============================================================

create or replace function public.tenant_activity(p_tenant text, p_days integer default 14)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_from timestamptz; v_out jsonb;
begin
  if not (auth_role() = 'operator'
          or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised';
  end if;

  /* IST days, because "was anyone in on Tuesday" is a question about the
     academy's calendar, not UTC's. A UTC day boundary would move 5.5 hours
     of every evening into the next day. */
  v_from := (ist_today() - greatest(p_days, 1))::timestamptz;

  select jsonb_build_object(
    'from_ist', (ist_today() - greatest(p_days, 1))::text,
    'last_seen', (select max(at) from events where tenant_id = p_tenant),

    /* one row per day: how many distinct visits, how many screens */
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('d', d, 'sessions', s, 'views', v) order by d)
        from (
          select (at at time zone 'Asia/Kolkata')::date as d,
                 count(distinct session_id) as s,
                 count(*) filter (where name = 'page_view') as v
            from events where tenant_id = p_tenant and at >= v_from
           group by 1
        ) x
    ), '[]'::jsonb),

    /* which screens they actually open */
    'pages', coalesce((
      select jsonb_agg(jsonb_build_object('page', page, 'views', v) order by v desc)
        from (
          select coalesce(page, '(none)') as page, count(*) as v
            from events
           where tenant_id = p_tenant and at >= v_from and name = 'page_view'
           group by 1 order by 2 desc limit 8
        ) y
    ), '[]'::jsonb),

    /* phone / tablet / desktop, and the browser family */
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc)
        from (
          select coalesce(props->>'dev', 'unknown') as k, count(distinct session_id) as n
            from events where tenant_id = p_tenant and at >= v_from
           group by 1 order by 2 desc
        ) z
    ), '[]'::jsonb),
    'browsers', coalesce((
      select jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc)
        from (
          select coalesce(props->>'br', 'unknown') as k, count(distinct session_id) as n
            from events where tenant_id = p_tenant and at >= v_from
           group by 1 order by 2 desc limit 4
        ) b
    ), '[]'::jsonb),

    /* the things that MATTER: a page view is traffic, these are the
       business actually happening (or failing) */
    'actions', jsonb_build_object(
      'bookings',      (select count(*) from events where tenant_id=p_tenant and at>=v_from and name='booking_requested'),
      'admissions',    (select count(*) from events where tenant_id=p_tenant and at>=v_from and name='admission_submitted'),
      'sign_in_failed',(select count(*) from events where tenant_id=p_tenant and at>=v_from and name='sign_in_failed'),
      'sessions',      (select count(distinct session_id) from events where tenant_id=p_tenant and at>=v_from)
    ),

    /* errors, grouped, so one broken screen is one line and not fifty */
    'errors', coalesce((
      select jsonb_agg(jsonb_build_object('page', page, 'msg', msg, 'n', n) order by n desc)
        from (
          select coalesce(page,'(none)') as page,
                 left(coalesce(props->>'msg', props->>'message', name), 90) as msg,
                 count(*) as n
            from events
           where tenant_id = p_tenant and at >= v_from and level = 'error'
           group by 1, 2 order by 3 desc limit 5
        ) e
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end
$function$;

revoke execute on function public.tenant_activity(text, integer) from public, anon;
grant  execute on function public.tenant_activity(text, integer) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it. Reads only.
-- ------------------------------------------------------------
do $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"operator"}}', true);

  r := tenant_activity('ska', 14);
  if r is null or r->'actions' is null then
    raise exception 'tenant_activity returned nothing useful';
  end if;
  if jsonb_typeof(r->'days') <> 'array' or jsonb_typeof(r->'pages') <> 'array' then
    raise exception 'days/pages are not arrays';
  end if;

  -- a tenant with no traffic must return empty arrays, never null
  r := tenant_activity('matchpoint', 1);
  if jsonb_typeof(r->'days') <> 'array' then
    raise exception 'a quiet tenant returned null instead of []';
  end if;

  -- staff of one academy must not read another's usage
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  begin
    perform tenant_activity('leo', 7);
    raise exception 'staff of ska read leo activity';
  exception when others then
    if sqlerrm <> 'not authorised' then raise; end if;
  end;
end $$;
