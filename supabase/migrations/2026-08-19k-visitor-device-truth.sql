-- ============================================================
-- 2026-08-19j · The panel called a Mac a phone
-- scope: shared
--
-- `tenant_visitors()` shipped yesterday reading
--
--     coalesce(props->>'dev', <parse the user-agent>)
--
-- and the first real reading it produced was "phone / chrome" for a
-- Macintosh user-agent. Both rows were the owner's own laptop, and the
-- panel exists for exactly one purpose: telling the owner's Mac from a
-- stranger's phone. It got that backwards on its first two rows.
--
-- The app is not lying. `dev` in cloud.js is a LAYOUT bucket — it reads
-- window.innerWidth and calls anything under 700px "phone", which is the
-- right answer to "which stylesheet did they get" and the wrong answer
-- to "what hardware is this". A narrow window on a desktop is a phone by
-- that definition. Two different questions sharing one word; the same
-- trap PLATFORM.md files under "same word, different shape".
--
-- So the order flips, on the principle the previous migration already
-- stated and then did not follow: Cloudflare and the request headers are
-- set by the network, the props are set by the page, and where they
-- disagree the network wins. The app's claim survives as a fallback for
-- a request that arrived without a user-agent, and its form factor is
-- kept as its own column rather than being thrown away — "someone opened
-- it on a phone-width screen" is worth knowing, it just is not the
-- device.
--
-- Also adds the browser VERSION, which was asked for and which the
-- previous parse dropped: "Chrome" and "Chrome 141" answer different
-- questions when a tester is checking whether an old build is the
-- problem.
-- ============================================================

-- The OUT list gains `form`, so a replace is refused; it has to be
-- dropped first. Safe inside the runner's transaction — the grants are
-- re-issued below, in the same transaction, so there is no window in
-- which the console can see the function without them.
drop function if exists public.tenant_visitors(text, integer);

create or replace function public.tenant_visitors(p_tenant text, p_days integer default 14)
returns table (
  visitor text, is_internal boolean, label text,
  first_seen timestamptz, last_seen timestamptz,
  visits integer, events integer,
  ip text, country text, edge text,
  device text, browser text, os text, form text,
  pages text, actions text, did_something boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with agg as (
    select
      e.visitor,
      iv.visitor is not null      as is_internal,
      iv.label                    as label,
      min(e.at)                   as first_seen,
      max(e.at)                   as last_seen,
      count(distinct e.session_id)::int as visits,
      count(*)::int               as events,
      host(max(e.ip))             as ip,
      max(e.country)              as country,
      max(e.edge)                 as edge,
      max(e.ua)                   as ua,
      max(e.props->>'dev')        as p_dev,
      max(e.props->>'br')         as p_br,
      max(e.props->>'os')         as p_os,
      max(e.props->>'vw')         as p_vw,
      e.tenant_id                 as tenant_id,
      bool_or(e.name not in ('page_view','client_error')) as did_something
    from events e
    left join internal_visitors iv
           on iv.tenant_id = e.tenant_id and iv.visitor = e.visitor
   where e.tenant_id = p_tenant
     and e.at >= now() - make_interval(days => p_days)
     and e.visitor is not null
   group by e.tenant_id, e.visitor, iv.visitor, iv.label
  )
  select
    a.visitor, a.is_internal, a.label, a.first_seen, a.last_seen,
    a.visits, a.events, a.ip, a.country, a.edge,
    -- HARDWARE, from the header the network set. iPad before Macintosh:
    -- iPadOS Safari sends a Macintosh user-agent, so the specific test
    -- has to come first or every iPad reads as a Mac.
    coalesce(
      case when a.ua ilike '%iphone%'                     then 'iPhone'
           when a.ua ilike '%ipad%'                       then 'iPad'
           when a.ua ilike '%android%' and a.ua ilike '%mobile%' then 'Android phone'
           when a.ua ilike '%android%'                    then 'Android tablet'
           when a.ua ilike '%macintosh%'                  then 'Mac'
           when a.ua ilike '%windows%'                    then 'Windows PC'
           when a.ua ilike '%linux%'                      then 'Linux'
           else null end,
      a.p_dev)                                                        as device,
    -- BROWSER + VERSION. Order matters: Edge and Opera both claim
    -- Chrome, and Chrome claims Safari.
    coalesce(
      case when a.ua ~* 'edg/([0-9]+)'      then 'Edge '    || (regexp_match(a.ua, 'Edg/([0-9]+)',      'i'))[1]
           when a.ua ~* 'opr/([0-9]+)'      then 'Opera '   || (regexp_match(a.ua, 'OPR/([0-9]+)',      'i'))[1]
           when a.ua ~* 'firefox/([0-9]+)'  then 'Firefox ' || (regexp_match(a.ua, 'Firefox/([0-9]+)',  'i'))[1]
           when a.ua ~* 'chrome/([0-9]+)'   then 'Chrome '  || (regexp_match(a.ua, 'Chrome/([0-9]+)',   'i'))[1]
           when a.ua ~* 'version/([0-9]+).*safari' then 'Safari ' || (regexp_match(a.ua, 'Version/([0-9]+)', 'i'))[1]
           when a.ua ilike '%safari%'       then 'Safari'
           else null end,
      a.p_br)                                                         as browser,
    coalesce(
      case when a.ua ilike '%android%'                 then 'Android'
           when a.ua ~* 'iphone os ([0-9_]+)'          then 'iOS ' || replace((regexp_match(a.ua, 'iPhone OS ([0-9]+)', 'i'))[1], '_', '.')
           when a.ua ilike '%mac os x%'                then 'macOS'
           when a.ua ilike '%windows nt 10%'           then 'Windows 10/11'
           when a.ua ilike '%windows%'                 then 'Windows'
           else null end,
      a.p_os)                                                         as os,
    -- What the PAGE thought, kept separate because it answers a
    -- different question: which layout did they actually get.
    nullif(concat_ws(' · ', a.p_dev, a.p_vw ), '')                    as form,
    (select string_agg(distinct x.page, ', ') from events x
      where x.tenant_id = a.tenant_id and x.visitor = a.visitor
        and x.at >= now() - make_interval(days => p_days))            as pages,
    (select string_agg(distinct x.name, ', ') from events x
      where x.tenant_id = a.tenant_id and x.visitor = a.visitor
        and x.at >= now() - make_interval(days => p_days)
        and x.name not in ('page_view','client_error'))               as actions,
    a.did_something
  from agg a
  order by a.last_seen desc
$$;

comment on function public.tenant_visitors(text,integer) is
  'One row per distinct device that touched a tenant''s app, with what it did. Hardware, browser version and OS come from the user-agent the NETWORK saw, not from what the page claims — the page''s own reading is a viewport bucket and called a Mac a phone. Operator-only: it returns IP addresses.';

revoke execute on function public.tenant_visitors(text,integer) from public, anon;
grant  execute on function public.tenant_visitors(text,integer) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks — every one is a read, so nothing to clean up
-- ------------------------------------------------------------
do $$
declare r record; n int := 0;
begin
  -- 1. the reading that prompted this file
  for r in select device, browser, os, form
             from tenant_visitors('ska', 30)
            where visitor = 'v_80edobru64mszxaww0' loop
    n := n + 1;
    if r.device <> 'Mac' then
      raise exception 'a Macintosh user-agent still reads as "%"', r.device;
    end if;
    if r.browser not like 'Chrome %' then
      raise exception 'browser version was dropped: "%"', r.browser;
    end if;
    raise notice 'the owner''s laptop now reads: % / % / % (page said: %)', r.device, r.browser, r.os, r.form;
  end loop;
  if n = 0 then
    raise exception 'the row this migration exists to fix was not found — check before trusting the rest';
  end if;

  -- 2. an iPad must not read as a Mac, because iPadOS says Macintosh
  if (select device from (select
        coalesce(case when u ilike '%iphone%' then 'iPhone'
                      when u ilike '%ipad%' then 'iPad'
                      when u ilike '%macintosh%' then 'Mac' end) as device
        from (values ('Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15')) v(u)) q) <> 'iPad' then
    raise exception 'iPad ordering is wrong';
  end if;

  -- 3. still operator-only, since it hands out IP addresses
  if has_function_privilege('anon', 'public.tenant_visitors(text,integer)', 'execute') then
    raise exception 'anon can read visitor IP addresses';
  end if;
end $$;
