-- ============================================================
-- 2026-08-19h · Tell a real visitor from the person who built the app
-- scope: shared
--
-- The question the console could not answer: a link was sent to Super
-- Kings, and did anyone actually open it? Today every event from the
-- owner's Mac, the owner's phone and a prospective customer looks
-- identical, so `ska` shows 294 events in two days and not one of them
-- is distinguishable from development.
--
-- WHAT THE CLIENT CANNOT TELL US. A browser does not know its own IP.
-- Anything the page sends about itself is also the thing a page can get
-- wrong or a developer can spoof by opening a different browser.
--
-- WHAT THE SERVER CAN SEE. Verified against the live API before writing
-- this: current_setting('request.headers') on an anon insert carries
--
--     cf-connecting-ip   49.47.217.72      the real client IP
--     user-agent         Mozilla/5.0 (…)   browser and OS
--     cf-ipcountry       IN                country, free
--     cf-ray             …-MAA             the Cloudflare edge, ≈ city
--
-- Cloudflare sets those, not the page, so a visitor cannot forge them
-- and the app does not have to be trusted to report them honestly.
--
-- IDENTITY. `session_id` is sessionStorage — it dies with the tab, so a
-- returning visitor reads as a new one. `visitor` is stable instead:
-- the client's own long-lived id when it sends one (props.vid), and
-- otherwise a hash of IP + user-agent, which is stable enough to tell
-- "the same phone came back" from "someone new opened the link".
--
-- EXCLUDING OURSELVES is the actual ask. internal_visitors marks a
-- device as the operator's, and every count in tenant_visitors() reports
-- both totals — with and without. Marking is a one-click operator
-- action rather than a config file, because the device you test from
-- changes more often than anyone updates a config file.
--
-- PRIVACY. An IP is personal data. It is readable only by the operator,
-- never by a tenant and never by anon — and because this table is about
-- to hold IPs, the blanket anon grant it inherited (arwdDxtm, the same
-- default that nearly published parents' phone numbers from bookings in
-- 2026-08-12t) is cut down to an insert of the six columns a page
-- legitimately sends. The origin columns are stamped by the trigger and
-- are not insertable at all, so a page cannot claim to be someone else.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Where the event came from
-- ------------------------------------------------------------
alter table public.events
  add column if not exists ip      inet,
  add column if not exists country text,
  add column if not exists edge    text,
  add column if not exists ua      text,
  add column if not exists visitor text;

comment on column public.events.ip      is 'Client IP from cf-connecting-ip. Server-stamped; operator-only. Personal data.';
comment on column public.events.visitor is 'Stable-ish identity: props.vid when the app sends one, else md5(ip||user-agent). Survives a tab close, unlike session_id.';
comment on column public.events.edge    is 'Cloudflare edge that served the request (cf-ray suffix, e.g. MAA = Chennai). A coarse location, and the only one available without asking permission.';

-- ------------------------------------------------------------
-- 2. Stamp it server-side. The client is never trusted for these.
-- ------------------------------------------------------------
create or replace function public.events_stamp_origin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare h jsonb; v_ip text; v_ua text; v_ray text;
begin
  h := coalesce(current_setting('request.headers', true)::jsonb, '{}'::jsonb);

  v_ip := coalesce(h->>'cf-connecting-ip', h->>'sb-forwarded-for',
                   split_part(coalesce(h->>'x-forwarded-for',''), ',', 1));
  v_ua := h->>'user-agent';
  v_ray := h->>'cf-ray';

  -- Overwrite, never merge: whatever the page sent for these is discarded.
  begin
    new.ip := nullif(btrim(v_ip), '')::inet;
  exception when others then
    new.ip := null;                      -- a malformed forwarded-for is not fatal
  end;
  new.ua      := nullif(v_ua, '');
  new.country := nullif(h->>'cf-ipcountry', '');
  new.edge    := nullif(split_part(coalesce(v_ray,''), '-', 2), '');

  -- Identity: the app's own durable id if it sends one, else a
  -- fingerprint. Both are opaque; neither is a name.
  new.visitor := coalesce(
    nullif(new.props->>'vid', ''),
    case when v_ip is null and v_ua is null then null
         else 'fp_' || left(md5(coalesce(v_ip,'') || '|' || coalesce(v_ua,'')), 16) end);

  return new;
end $$;

drop trigger if exists events_stamp_origin on public.events;
create trigger events_stamp_origin
  before insert on public.events
  for each row execute function public.events_stamp_origin();

create index if not exists events_tenant_visitor_at_idx
  on public.events (tenant_id, visitor, at desc);

-- ------------------------------------------------------------
-- 3. anon may insert six columns and read nothing
-- ------------------------------------------------------------
revoke all on public.events from anon;
grant insert (tenant_id, name, props, session_id, page, level)
  on public.events to anon;

-- ------------------------------------------------------------
-- 4. "That one is me"
-- ------------------------------------------------------------
create table if not exists public.internal_visitors (
  id         bigserial primary key,
  tenant_id  text not null,
  visitor    text not null,
  label      text,
  added_at   timestamptz not null default now(),
  unique (tenant_id, visitor)
);
alter table public.internal_visitors enable row level security;
revoke all on public.internal_visitors from public, anon, authenticated;
grant select, insert, update, delete on public.internal_visitors to service_role;

comment on table public.internal_visitors is
  'Devices that are ours, not a customer''s. Excluded from the real-visitor counts in tenant_visitors(). Operator-managed through mark_visitor(); no tenant can see or change it.';

create or replace function public.mark_visitor(p_tenant text, p_visitor text, p_label text default null, p_internal boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth_role() <> 'operator' and not is_service() then
    raise exception 'operator only';
  end if;
  if p_internal then
    insert into internal_visitors (tenant_id, visitor, label)
    values (p_tenant, p_visitor, nullif(p_label,''))
    on conflict (tenant_id, visitor) do update set label = excluded.label;
  else
    delete from internal_visitors where tenant_id = p_tenant and visitor = p_visitor;
  end if;
end $$;

revoke execute on function public.mark_visitor(text,text,text,boolean) from public, anon;
grant  execute on function public.mark_visitor(text,text,text,boolean) to authenticated, service_role;

-- ------------------------------------------------------------
-- 5. One row per visitor, with what they actually did
-- ------------------------------------------------------------
create or replace function public.tenant_visitors(p_tenant text, p_days integer default 14)
returns table (
  visitor text, is_internal boolean, label text,
  first_seen timestamptz, last_seen timestamptz,
  visits integer, events integer,
  ip text, country text, edge text,
  device text, browser text, os text,
  pages text, actions text, did_something boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    e.visitor,
    iv.visitor is not null                                   as is_internal,
    iv.label,
    min(e.at)                                                as first_seen,
    max(e.at)                                                as last_seen,
    count(distinct e.session_id)::int                        as visits,
    count(*)::int                                            as events,
    host(max(e.ip))                                          as ip,
    max(e.country)                                           as country,
    max(e.edge)                                              as edge,
    -- props from the app when it sends them; the user-agent otherwise.
    coalesce(max(e.props->>'dev'),
             case when max(e.ua) ilike '%iphone%'  then 'iPhone'
                  when max(e.ua) ilike '%ipad%'    then 'iPad'
                  when max(e.ua) ilike '%android%' then 'Android'
                  when max(e.ua) ilike '%macintosh%' then 'Mac'
                  when max(e.ua) ilike '%windows%' then 'Windows'
                  else null end)                             as device,
    coalesce(max(e.props->>'br'),
             case when max(e.ua) ilike '%edg/%'    then 'Edge'
                  when max(e.ua) ilike '%chrome%'  then 'Chrome'
                  when max(e.ua) ilike '%firefox%' then 'Firefox'
                  when max(e.ua) ilike '%safari%'  then 'Safari'
                  else null end)                             as browser,
    max(e.props->>'os')                                      as os,
    (select string_agg(distinct x.page, ', ') from events x
      where x.tenant_id = e.tenant_id and x.visitor = e.visitor
        and x.at >= now() - make_interval(days => p_days))    as pages,
    (select string_agg(distinct x.name, ', ') from events x
      where x.tenant_id = e.tenant_id and x.visitor = e.visitor
        and x.at >= now() - make_interval(days => p_days)
        and x.name not in ('page_view','client_error'))       as actions,
    bool_or(e.name not in ('page_view','client_error'))       as did_something
  from events e
  left join internal_visitors iv
         on iv.tenant_id = e.tenant_id and iv.visitor = e.visitor
 where e.tenant_id = p_tenant
   and e.at >= now() - make_interval(days => p_days)
   and e.visitor is not null
 group by e.tenant_id, e.visitor, iv.visitor, iv.label
 order by max(e.at) desc
$$;

comment on function public.tenant_visitors(text,integer) is
  'One row per distinct visitor for a tenant: when, how often, from what device and IP, which pages, and whether they did anything beyond looking. is_internal marks our own test devices so real traction can be counted separately.';

revoke execute on function public.tenant_visitors(text,integer) from public, anon;
grant  execute on function public.tenant_visitors(text,integer) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  -- anon may still insert (a telemetry outage is a real cost) …
  if not has_column_privilege('anon','public.events','name','INSERT') then
    raise exception 'anon can no longer insert events — every tenant just went dark';
  end if;
  -- … but may not read, and may not claim an origin
  if has_table_privilege('anon','public.events','SELECT') then
    raise exception 'anon can SELECT events, which now hold IP addresses';
  end if;
  if has_column_privilege('anon','public.events','ip','INSERT') then
    raise exception 'anon can insert its own ip — the stamp is forgeable';
  end if;

  select count(*) into n from pg_trigger t join pg_class c on c.oid=t.tgrelid
   where c.relname='events' and t.tgname='events_stamp_origin' and not t.tgisinternal;
  if n <> 1 then raise exception 'the origin trigger is not installed'; end if;

  raise notice 'events: anon inserts six columns, reads none, and cannot stamp its own origin';
end $$;
