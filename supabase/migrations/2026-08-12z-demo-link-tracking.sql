-- Who opened the demo, and how far they went.
--
-- THE APPROACH, AND WHY NOT THE TWO OBVIOUS ONES
--
-- Geolocation: IP geolocation is city-level at best and wrong often —
-- an Airtel subscriber in Kukatpally frequently resolves to Mumbai. It
-- cannot tell two prospects in Hyderabad apart, which is the only question
-- that matters here, and it needs a third-party lookup from a page that
-- should make no external calls. It answers a worse question worse.
--
-- Phone number: a browser cannot read the visitor's number. Not possible.
--
-- What we DO control is the link. Each lead gets its own, so an open is
-- attributable by construction rather than inferred:
--
--   dashboard.html?r=<ref_code>
--
-- ref_code is a stored generated column over the lead id, so it is stable
-- for the life of the lead and no code path can reassign it — the same
-- reason the A/B arm is generated.
--
-- WHAT IS AND IS NOT COLLECTED
--
-- Page, timestamp, a client-generated session id, and mobile-vs-desktop.
-- No IP address, no fingerprint, no third-party tracker. That is
-- proportionate for telling whether a business we messaged opened the link
-- we sent, and it is all the sales question needs.
--
-- HONEST LIMITS, so nobody over-reads the dashboard:
--   · demo_track() is anon-callable, so a visit is forgeable by anyone
--     holding the public key. Acceptable for the same reason the events
--     table accepts it: these are engagement counts, not authorisation.
--   · A forwarded link reports as the original lead. That is usually a
--     buying signal (they sent it to a partner), not noise — but it means
--     "3 sessions" can be three people, not three visits.
--   · It returns ok for an unknown ref, on purpose. Answering "no such
--     lead" would turn it into an enumeration oracle for the ref space.
--
-- WHY THE VISITS TABLE TAKES NO ANON GRANT
--
-- demo_track() is SECURITY DEFINER, so it writes as the owner. anon needs
-- EXECUTE on the function and nothing at all on the table — so a leaked
-- key cannot read back who has been visiting, only add a row through the
-- one shaped path.
--
-- Scope: shared. Operator-only reads; one deliberately anon-callable write.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

-- ─────────────────────────────────────────────────────────────
-- 1. A stable per-lead code
-- ─────────────────────────────────────────────────────────────
alter table sales.leads
  add column if not exists ref_code text
    generated always as (substr(md5(id::text), 1, 7)) stored;

comment on column sales.leads.ref_code is
  'Opaque per-lead code for the demo link. Generated from the id and '
  'STORED, so it is stable for the life of the lead and cannot be '
  'reassigned. 7 hex chars = 268M values; guessing one gains nothing '
  'because the demo is public anyway.';

create unique index if not exists leads_ref_code on sales.leads (ref_code);

-- ─────────────────────────────────────────────────────────────
-- 2. Visits
-- ─────────────────────────────────────────────────────────────
create table if not exists sales.demo_visits (
  id         bigserial primary key,
  lead_id    uuid references sales.leads(id) on delete cascade,
  -- kept even when no lead matches, so stray or forged traffic is visible
  -- rather than silently dropped
  ref_code   text,
  page       text,
  session_id text,
  device     text check (device is null or device in ('mobile', 'desktop')),
  at         timestamptz not null default now()
);

comment on table sales.demo_visits is
  'One row per demo page view. No IP, no fingerprint, no third-party '
  'tracker. Written only by demo_track(); the table itself carries no '
  'anon grant, so a leaked key cannot read visits back.';

create index if not exists demo_visits_lead on sales.demo_visits (lead_id, at desc);
create index if not exists demo_visits_at   on sales.demo_visits (at desc);
create index if not exists demo_visits_sess on sales.demo_visits (session_id);

alter table sales.demo_visits enable row level security;
revoke all on sales.demo_visits from public;
grant select, insert on sales.demo_visits to service_role;
grant usage, select on sequence sales.demo_visits_id_seq to service_role;

-- ─────────────────────────────────────────────────────────────
-- 3. The one anon-callable write
-- ─────────────────────────────────────────────────────────────
create or replace function public.demo_track(
  p_ref     text default null,
  p_page    text default null,
  p_session text default null,
  p_device  text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_lead uuid; v_ref text; v_recent int;
begin
  -- No tenant argument, and nothing here reads a tenant table other than
  -- sales.leads by ref_code. There is no parameter that could point this
  -- at another academy's data — which is the property that made the
  -- 0009/0010 functions unsafe and makes this one safe.
  v_ref := nullif(btrim(coalesce(p_ref, '')), '');

  -- clamp everything: this is an unauthenticated endpoint
  if v_ref is not null and v_ref !~ '^[0-9a-f]{1,16}$' then
    v_ref := null;                       -- not a ref shape; record as stray
  end if;

  select id into v_lead from sales.leads where ref_code = v_ref;

  -- cheap flood guard: one session cannot log more than 200 views an hour.
  -- Not security — it stops a loop or a bot from drowning the signal.
  if p_session is not null then
    select count(*) into v_recent from sales.demo_visits
     where session_id = p_session and at > now() - interval '1 hour';
    if v_recent > 200 then
      return jsonb_build_object('ok', true);
    end if;
  end if;

  insert into sales.demo_visits (lead_id, ref_code, page, session_id, device)
  values (v_lead, v_ref,
          left(nullif(btrim(coalesce(p_page, '')), ''), 120),
          left(nullif(btrim(coalesce(p_session, '')), ''), 64),
          case when lower(coalesce(p_device, '')) = 'mobile' then 'mobile'
               when lower(coalesce(p_device, '')) = 'desktop' then 'desktop'
               else null end);

  -- Always ok, even for an unknown ref. Reporting "no such lead" would
  -- make this an enumeration oracle.
  return jsonb_build_object('ok', true);
end $$;

comment on function public.demo_track(text, text, text, text) is
  'Records a demo page view against a lead ref code. Deliberately '
  'anon-callable: the public demo has no session. Takes no tenant '
  'argument. Returns ok for an unknown ref so it cannot be used to '
  'enumerate ref codes.';

-- ─────────────────────────────────────────────────────────────
-- 4. Reading it back — operator only
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_demo_activity(p_days int default 30)
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare result jsonb;
begin
  perform assert_operator();

  select coalesce(jsonb_agg(o order by last_at desc), '[]'::jsonb)
    into result
    from (
      select max(v.at) as last_at,
             jsonb_build_object(
               'lead_id',   l.id,
               'name',      l.name,
               'sport',     l.sport,
               'area',      l.area,
               'phone',     l.phone,
               'stage',     l.stage,
               'score',     l.score,
               'sessions',  count(distinct v.session_id),
               'views',     count(*),
               'pages',     (select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
                               from (select v2.page as p from sales.demo_visits v2
                                      where v2.lead_id = l.id
                                        and v2.page is not null) q),
               'device',    max(v.device),
               'first_ist', to_char(min(v.at) at time zone 'Asia/Kolkata',
                                    'YYYY-MM-DD HH24:MI'),
               'last_ist',  to_char(max(v.at) at time zone 'Asia/Kolkata',
                                    'YYYY-MM-DD HH24:MI'),
               -- the whole point: who to ring today
               'heat', case
                         when count(distinct v.session_id) >= 2 then 'hot'
                         when count(*) >= 3 then 'warm'
                         else 'opened' end
             ) as o
        from sales.demo_visits v
        join sales.leads l on l.id = v.lead_id
       where v.at > now() - make_interval(days => greatest(1, coalesce(p_days, 30)))
       group by l.id, l.name, l.sport, l.area, l.phone, l.stage, l.score
    ) q;

  return result;
end $$;

-- Stray traffic: opens with no matching lead. Worth seeing separately —
-- it is either a forwarded link, a scraper, or a bug in the client.
create or replace function public.sales_demo_stray(p_days int default 30)
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare result jsonb;
begin
  perform assert_operator();
  select jsonb_build_object(
    'views',    count(*),
    'sessions', count(distinct session_id),
    'with_no_ref', count(*) filter (where ref_code is null),
    'unknown_refs', count(distinct ref_code) filter (where ref_code is not null)
  ) into result
    from sales.demo_visits
   where lead_id is null
     and at > now() - make_interval(days => greatest(1, coalesce(p_days, 30)));
  return result;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 5. Surface the link and the signal on every lead row
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_leads(
  p_stage    text default null,
  p_priority text default null,
  p_sport    text default null,
  p_search   text default null,
  p_callable boolean default null,
  p_limit    int default 200,
  p_offset   int default 0
) returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare result jsonb;
begin
  perform assert_operator();

  select coalesce(jsonb_agg(obj order by ord_score desc, ord_conf, ord_name),
                  '[]'::jsonb)
    into result
    from (
      select l.score as ord_score,
             case l.phone_confidence when 'verified'  then 0
                                     when 'directory' then 1
                                     when 'malformed' then 2
                                     else 3 end as ord_conf,
             lower(l.name) as ord_name,
             jsonb_build_object(
               'id', l.id, 'name', l.name, 'contact_name', l.contact_name,
               'sport', l.sport, 'area', l.area, 'city', l.city,
               'phone', l.phone, 'alt_phones', to_jsonb(l.alt_phones),
               'phone_confidence', l.phone_confidence,
               'phone_source_url', l.phone_source_url,
               'website_or_social', l.website_or_social,
               'branches', l.branches, 'students_est', l.students_est,
               'fees_seen', l.fees_seen, 'tech_signal', l.tech_signal,
               'notes', l.notes, 'score', l.score, 'variant', l.variant,
               'ref_code', l.ref_code,
               'demo_link', 'https://sujittarun.github.io/AcademyManagerDemo/'
                            || 'dashboard.html?r=' || l.ref_code,
               'demo_views',    (select count(*) from sales.demo_visits v
                                  where v.lead_id = l.id),
               'demo_sessions', (select count(distinct v.session_id)
                                   from sales.demo_visits v
                                  where v.lead_id = l.id),
               'demo_last_ist', (select to_char(max(v.at) at time zone 'Asia/Kolkata',
                                                'YYYY-MM-DD HH24:MI')
                                   from sales.demo_visits v
                                  where v.lead_id = l.id),
               'priority', case when l.score >= 8 then 'A'
                                when l.score >= 6 then 'B' else 'C' end,
               'suggested_plan',
                 case when coalesce(l.students_est,0) > 150
                        or l.branches >= 4 then 'Enterprise (custom)'
                      when coalesce(l.students_est,0) > 100
                        or l.branches >= 2 then 'Pro 3999'
                      when coalesce(l.students_est,0) > 50 then 'Growth 1999'
                      when coalesce(l.students_est,0) > 0 then 'Starter 899'
                      else 'Growth 1999 (assumed)' end,
               'stage', l.stage, 'do_not_contact', l.do_not_contact,
               'owner', l.owner, 'last_touch_at', l.last_touch_at,
               'next_action_on', l.next_action_on,
               'touch_count', (select count(*) from sales.touches t
                                where t.lead_id = l.id),
               'last_outcome', (select t.outcome from sales.touches t
                                 where t.lead_id = l.id
                                 order by t.occurred_at desc limit 1),
               'wa_link', case when l.phone is not null
                                and not l.do_not_contact
                          then 'https://wa.me/91' || l.phone else null end
             ) as obj
        from sales.leads l
       where (p_stage    is null or l.stage = p_stage)
         and (p_sport    is null or l.sport ilike '%' || p_sport || '%')
         and (p_priority is null or p_priority =
               case when l.score >= 8 then 'A'
                    when l.score >= 6 then 'B' else 'C' end)
         and (p_callable is null or p_callable = (
               l.phone is not null
               and l.phone_confidence in ('verified','directory')
               and not l.do_not_contact))
         and (p_search is null or p_search = '' or
              l.name ilike '%' || p_search || '%' or
              coalesce(l.area,'')  ilike '%' || p_search || '%' or
              coalesce(l.phone,'') ilike '%' || p_search || '%' or
              exists (select 1 from unnest(l.alt_phones) a
                       where a ilike '%' || p_search || '%'))
       order by l.score desc, ord_conf, lower(l.name)
       limit greatest(1, least(coalesce(p_limit,200), 1000))
      offset greatest(0, coalesce(p_offset,0))
    ) q;

  return result;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 6. Grants. demo_track is anon by design; everything else is not.
-- ─────────────────────────────────────────────────────────────
revoke execute on function public.demo_track(text,text,text,text) from public;
grant  execute on function public.demo_track(text,text,text,text)
  to anon, authenticated, service_role;

revoke execute on function public.sales_demo_activity(int) from public, anon;
grant  execute on function public.sales_demo_activity(int)
  to authenticated, service_role;
revoke execute on function public.sales_demo_stray(int) from public, anon;
grant  execute on function public.sales_demo_stray(int)
  to authenticated, service_role;
revoke execute on function
  public.sales_leads(text,text,text,text,boolean,int,int) from public, anon;
grant  execute on function
  public.sales_leads(text,text,text,text,boolean,int,int)
  to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 7. rpc_audit() must stay clean. demo_track joins the deliberately
--    anon-callable list, with its reason stated where the next reader
--    will find it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.rpc_audit()
returns table(fn text, args text, touches text)
language sql stable security definer set search_path = public as $$
  with app_schemas as (
    select oid, nspname from pg_namespace
     where nspname in ('public', 'genalpha')
  ),
  tenant_tables as (
    select c.relname::text as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'tenant_id'
                      and not a.attisdropped)
  )
  select (n.nspname || '.' || p.proname)::text,
         pg_get_function_identity_arguments(p.oid),
         (select string_agg(distinct tt.t, ', ')
            from tenant_tables tt
           where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
    from pg_proc p
    join app_schemas n on n.oid = p.pronamespace
   where p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute')
     and (n.nspname || '.' || p.proname) <> all (array[
           'public.request_booking',
           'public.submit_application',
           'public.tenant_exists',
           'public.tenant_publishes_timetable',
           'public.sync_ingest',
           'genalpha.submit_admission_form',
           'genalpha.peek_next_admission_reg_no',
           -- Records a page view on the public demo against an opaque
           -- lead ref code. Takes no tenant argument, writes one row to
           -- sales.demo_visits, and reads nothing back to the caller —
           -- it returns {ok:true} even for an unknown ref so it cannot
           -- be used to enumerate. Reviewed 2026-08-12.
           'public.demo_track'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$$;

revoke execute on function public.rpc_audit() from public, anon;
grant  execute on function public.rpc_audit() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 8. Assertions
-- ─────────────────────────────────────────────────────────────
do $$
declare n int; extra text;
begin
  -- ref codes must exist and be unique
  select count(*) into n from sales.leads where ref_code is null;
  if n > 0 then raise exception '% leads have no ref_code', n; end if;
  select count(*) into n from (
    select ref_code from sales.leads group by ref_code having count(*) > 1) d;
  if n > 0 then raise exception '% duplicate ref_code(s)', n; end if;

  -- anon may execute demo_track and NOTHING else under sales_
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    raise exception 'anon can execute % sales_ function(s)', n;
  end if;
  if not has_function_privilege('anon', 'public.demo_track(text,text,text,text)', 'execute') then
    raise exception 'anon cannot execute demo_track — the public demo could not report';
  end if;

  -- anon must not reach the visits table directly
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'sales' and grantee in ('anon','authenticated','PUBLIC');
  if n > 0 then
    raise exception 'sales tables carry % grant(s) to anon/authenticated/PUBLIC', n;
  end if;

  -- and rpc_audit must be empty apart from the reviewed list
  select count(*), coalesce(string_agg(fn, ', '), '') into n, extra
    from rpc_audit();
  if n > 0 then
    raise exception 'rpc_audit() is not empty: %', extra;
  end if;

  raise notice 'demo link tracking wired; rpc_audit clean; anon can only call demo_track';
end $$;
