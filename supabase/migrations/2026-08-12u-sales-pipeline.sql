-- Sales pipeline: the prospects we are selling Academy Manager TO.
--
-- WHY A SEPARATE SCHEMA, AND NOT public
--
-- Every table in `public` is tenant data carrying `tenant_id`, and the
-- whole security model is "RLS scoped by tenant". A sales lead has no
-- tenant — it is our own business data about a company that is not a
-- customer yet. Dropping a tenant_id-less table into `public` invites the
-- next reader to "fix" it by adding a tenant policy, and puts it in front
-- of shared_widening_audit() as permanent noise.
--
-- The decisive reason is narrower: PostgREST only serves the schemas in
-- its exposed list (`public`, `genalpha`). A table in `sales` is therefore
-- **not reachable over the API at all** — not with the anon key, not with
-- a tenant staff token, not with a leaked one. The only way in is through
-- the guarded SECURITY DEFINER functions below, which live in `public` on
-- purpose so that rpc_audit(), authenticated_audit() and policy_fn_audit()
-- keep seeing them. Tables outside the audits, entry points inside them.
--
-- WHY THAT MATTERS MORE HERE THAN USUAL
--
-- This is the first table on the platform holding personal contact data
-- for people who are NOT our customers and have not opted in. Machaxi's
-- repo is kept private forever because its git history holds member names
-- and phone numbers; `purge-pii-history.sh` exists for the same reason.
-- So: the numbers live here, in a schema no client can reach, and the
-- research CSVs must never be committed. There is a .gitignore in
-- marketing/leads/ enforcing that.
--
-- DO-NOT-CONTACT SURVIVES RE-IMPORT
--
-- `sales.dnc` is keyed on the phone number, not on the lead id, and
-- sales_import() checks it before inserting. If someone asks us to stop
-- and a later CSV re-imports them, they come back already suppressed.
-- A do-not-contact list that a re-import can undo is not a
-- do-not-contact list.
--
-- SCORE IS A GENERATED COLUMN
--
-- The lead score decides who gets called first, so it must not be able to
-- disagree with itself between the importer, the dashboard and a manual
-- query. It is computed by one IMMUTABLE function and STORED, which means
-- there is exactly one authority and no code path that can write a stale
-- one. Changing the formula means re-running the ALTER at the bottom of
-- this file's pattern — deliberately slightly annoying, so it stays
-- deliberate.
--
-- Scope: shared. Operator-only; no tenant reaches any of it.
--
-- No begin/commit here on purpose: migrate.sh wraps the file in one
-- transaction and the ledger row rides inside it. A commit in this file
-- would end that transaction, and --dry-run would apply for real while
-- still reporting that nothing was kept.

-- ─────────────────────────────────────────────────────────────
-- 1. The operator guard, which did not exist yet
-- ─────────────────────────────────────────────────────────────
-- auth_role() and is_service() already exist. Every operator function so
-- far has inlined `if auth_role() <> 'operator' then raise`. The name
-- assert_operator is already in authenticated_audit()'s guard regex
-- (2026-08-10n), so the audit has been expecting it; this defines it.
create or replace function public.assert_operator()
returns void language plpgsql stable security invoker
set search_path = public as $$
begin
  if is_service() then return; end if;
  if auth_role() <> 'operator' then
    raise exception 'operator only' using errcode = '42501';
  end if;
end $$;

comment on function public.assert_operator() is
  'Raises unless the caller is the console operator or a service connection. '
  'Guard for operator-only definer functions.';

-- ─────────────────────────────────────────────────────────────
-- 2. Schema
-- ─────────────────────────────────────────────────────────────
create schema if not exists sales;

comment on schema sales is
  'Academy Manager''s own sales pipeline — prospects we are selling to. '
  'NOT tenant data, no tenant_id. Deliberately not in PostgREST''s exposed '
  'schema list: reachable only through the guarded operator RPCs in public.';

revoke all on schema sales from public;
grant usage on schema sales to postgres, service_role;

-- ─────────────────────────────────────────────────────────────
-- 3. Scoring — one immutable authority
-- ─────────────────────────────────────────────────────────────
create or replace function sales.lead_score(
  p_branches int,
  p_students int,
  p_tech     text,
  p_evidence text,
  p_fees     text,
  p_size     text
) returns int language sql immutable as $$
  select greatest(0, least(10,
      -- runs coached batches at all: this is the product
      case when coalesce(p_evidence, '') ~*
        '(batch|monthly|coach|class|programme|program|enrol|train|academy)'
        then 3 else 0 end
      -- registration is manual => the register is on paper and the fees
      -- are in a notebook. The strongest buying signal there is.
    + case when coalesce(p_tech, '') ~*
             '(google form|whatsapp|instagram only|no website|manual|none|no online|no portal|no app|walk.?in|phone only)'
           and coalesce(p_tech, '') !~*
             '(parent login|parent portal|student login|own app|erp|booking app)'
           then 3 else 0 end
      -- multi-centre is where fee rules and coach scoping earn their keep,
      -- and it moves the deal from 899 to 3999
    + case when coalesce(p_branches, 1) >= 2 then 2 else 0 end
    + case when p_students between 50 and 150 then 2
           when p_students > 150               then 1
           when p_students between 1 and 24    then -2
           else 0 end
    + case when coalesce(p_fees, '') <> '' then 1 else 0 end
    + case when coalesce(p_size, '') ~* '(coach|instructor|trainer)'
           then 1 else 0 end
      -- someone already sold them something: requalify before spending time
    + case when coalesce(p_tech, '') ~*
             '(parent login|parent portal|student login|own app|erp|booking app|already uses)'
           then -3 else 0 end
      -- booking-only venue: not our customer
    + case when coalesce(p_evidence, '') ~*
             '(court hire|only booking|rental only|turf rental)'
           then -5 else 0 end
  ))
$$;

comment on function sales.lead_score(int, int, text, text, text, text) is
  'The lead score, 0-10. IMMUTABLE because sales.leads.score is a stored '
  'generated column over it — one authority, so the importer and the '
  'dashboard cannot disagree. Mirrors marketing/leads/PLAYBOOK.md.';

-- ─────────────────────────────────────────────────────────────
-- 4. Leads
-- ─────────────────────────────────────────────────────────────
create table if not exists sales.leads (
  id                uuid primary key default gen_random_uuid(),

  -- normalised name; the upsert key, so a re-import updates rather than
  -- duplicating. Computed by sales_import(), never typed by hand.
  import_key        text not null unique,

  name              text not null,
  contact_name      text,
  sport             text,
  area              text,
  city              text not null default 'Hyderabad',

  phone             text,
  phone_confidence  text not null default 'none'
                    check (phone_confidence in
                          ('verified', 'directory', 'malformed', 'none')),
  -- provenance. Every number must be traceable to the page it was read
  -- off, or a caller cannot tell a real number from a guessed one.
  phone_source_url  text,
  website_or_social text,

  branches          int not null default 1 check (branches >= 0),
  students_est      int check (students_est is null or students_est >= 0),
  fees_seen         text,
  tech_signal       text,
  coaching_evidence text,
  size_signal       text,
  notes             text,

  score             int generated always as (
                      sales.lead_score(branches, students_est, tech_signal,
                                       coaching_evidence, fees_seen,
                                       size_signal)
                    ) stored,

  stage             text not null default 'new'
                    check (stage in ('new', 'contacted', 'replied',
                                     'call_booked', 'demo_done',
                                     'won', 'lost')),
  do_not_contact    boolean not null default false,
  owner             text,

  -- when a lead becomes a tenant, this is the join back to the platform
  converted_tenant_id text references public.tenants(id),

  last_touch_at     timestamptz,
  next_action_on    date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- a lead marked won must say which tenant it became, or the funnel
  -- cannot be reconciled against the portfolio
  constraint won_names_its_tenant
    check (stage <> 'won' or converted_tenant_id is not null)
);

comment on table sales.leads is
  'Sales prospects for Academy Manager. Operator-only. No tenant_id: this '
  'is our data about companies that are not customers. Third-party PII — '
  'never expose over PostgREST, never commit the source CSVs.';
comment on column sales.leads.phone_source_url is
  'The page the number was actually read off. A number with no source was '
  'guessed, and a guessed number burns a real call.';
comment on column sales.leads.import_key is
  'Normalised name. Upsert key for sales_import(), so re-running an import '
  'updates instead of duplicating.';

create index if not exists leads_triage
  on sales.leads (score desc, phone_confidence, stage);
create index if not exists leads_stage on sales.leads (stage);
create index if not exists leads_sport on sales.leads (sport);
create index if not exists leads_phone on sales.leads (phone)
  where phone is not null;

-- ─────────────────────────────────────────────────────────────
-- 5. Touches — every outreach attempt, in and out
-- ─────────────────────────────────────────────────────────────
create table if not exists sales.touches (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references sales.leads(id) on delete cascade,
  channel     text not null
              check (channel in ('whatsapp', 'call', 'email', 'dm', 'visit')),
  direction   text not null default 'out' check (direction in ('out', 'in')),
  template    text,   -- which message variant, e.g. opener_cricket
  body        text,   -- what was actually sent, or a note on what they said
  outcome     text not null default 'sent'
              check (outcome in ('sent', 'delivered', 'read', 'replied',
                                 'no_answer', 'wrong_number', 'failed',
                                 'not_interested')),
  sent_from   text,   -- the sending number, so a restricted one is traceable
  by_user     text,
  notes       text,
  occurred_at timestamptz not null default now()
);

comment on table sales.touches is
  'One row per outreach attempt. sent_from records which number sent it, '
  'so if a sender gets restricted we know exactly what it had touched.';

create index if not exists touches_lead
  on sales.touches (lead_id, occurred_at desc);
create index if not exists touches_when on sales.touches (occurred_at desc);

-- ─────────────────────────────────────────────────────────────
-- 6. Do-not-contact — keyed on the number, so re-import cannot undo it
-- ─────────────────────────────────────────────────────────────
create table if not exists sales.dnc (
  phone    text primary key,
  reason   text,
  added_by text,
  added_at timestamptz not null default now()
);

comment on table sales.dnc is
  'Numbers that asked us to stop. Keyed on phone, not lead id, so a later '
  'CSV re-import cannot resurrect them. Checked by sales_import() and '
  'enforced by sales_log_touch().';

-- ─────────────────────────────────────────────────────────────
-- 7. Lock it all down. RLS with no policies = owner only, which is
--    what the definer functions run as. Belt and braces on top of the
--    schema not being PostgREST-exposed.
-- ─────────────────────────────────────────────────────────────
alter table sales.leads   enable row level security;
alter table sales.touches enable row level security;
alter table sales.dnc     enable row level security;

revoke all on all tables in schema sales from public;
grant select, insert, update, delete
  on all tables in schema sales to service_role;

-- updated_at
create or replace function sales.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists leads_updated_at on sales.leads;
create trigger leads_updated_at before update on sales.leads
  for each row execute function sales.touch_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 8. The operator API. In `public` so the audits see it; every body
--    starts with assert_operator().
-- ─────────────────────────────────────────────────────────────

-- Normalise an Indian number to 10 digits, or null. Never invents digits:
-- anything that is not recognisably a number comes back null so the row
-- is stored as unreachable rather than as plausible-looking garbage.
create or replace function sales.norm_phone(p text)
returns text language sql immutable as $$
  with d as (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as x)
  select case
           when length(x) = 12 and left(x, 2) = '91'
                and substr(x, 3, 1) between '6' and '9' then substr(x, 3)
           when length(x) = 11 and left(x, 1) = '0'
                and substr(x, 2, 1) between '6' and '9' then substr(x, 2)
           when length(x) = 10 and left(x, 1) between '6' and '9' then x
           else null
         end
    from d
$$;

comment on function sales.norm_phone(text) is
  'Ten-digit Indian mobile, or NULL. Landlines and malformed values return '
  'NULL on purpose: a half-recognised number must not look callable.';

-- Dashboard header counts.
create or replace function public.sales_pipeline()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare result jsonb;
begin
  perform assert_operator();

  select jsonb_build_object(
    'total',      (select count(*) from sales.leads),
    'callable',   (select count(*) from sales.leads
                    where phone is not null
                      and phone_confidence in ('verified', 'directory')
                      and not do_not_contact),
    'verified',   (select count(*) from sales.leads
                    where phone_confidence = 'verified'),
    'no_phone',   (select count(*) from sales.leads where phone is null),
    'dnc',        (select count(*) from sales.dnc),
    'by_stage',   (select coalesce(jsonb_object_agg(stage, n), '{}'::jsonb)
                     from (select stage, count(*) n from sales.leads
                            group by stage) s),
    'by_priority',(select coalesce(jsonb_object_agg(p, n), '{}'::jsonb)
                     from (select case when score >= 8 then 'A'
                                       when score >= 6 then 'B'
                                       else 'C' end as p, count(*) n
                             from sales.leads group by 1) q),
    'by_sport',   (select coalesce(jsonb_object_agg(sport, n), '{}'::jsonb)
                     from (select coalesce(sport, 'Unknown') sport, count(*) n
                             from sales.leads group by 1) sp),
    'touches_7d', (select count(*) from sales.touches
                    where occurred_at > now() - interval '7 days'),
    'replies_7d', (select count(*) from sales.touches
                    where occurred_at > now() - interval '7 days'
                      and (direction = 'in' or outcome = 'replied')),
    'due_today',  (select count(*) from sales.leads
                    where next_action_on <= current_date
                      and stage not in ('won', 'lost')
                      and not do_not_contact)
  ) into result;

  return result;
end $$;

-- The list. p_* are all optional filters.
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
               'id',            l.id,
               'name',          l.name,
               'contact_name',  l.contact_name,
               'sport',         l.sport,
               'area',          l.area,
               'city',          l.city,
               'phone',         l.phone,
               'phone_confidence', l.phone_confidence,
               'phone_source_url', l.phone_source_url,
               'website_or_social', l.website_or_social,
               'branches',      l.branches,
               'students_est',  l.students_est,
               'fees_seen',     l.fees_seen,
               'tech_signal',   l.tech_signal,
               'notes',         l.notes,
               'score',         l.score,
               'priority',      case when l.score >= 8 then 'A'
                                     when l.score >= 6 then 'B'
                                     else 'C' end,
               'suggested_plan',
                 case when coalesce(l.students_est, 0) > 150
                        or l.branches >= 4 then 'Enterprise (custom)'
                      when coalesce(l.students_est, 0) > 100
                        or l.branches >= 2 then 'Pro 3999'
                      when coalesce(l.students_est, 0) > 50 then 'Growth 1999'
                      when coalesce(l.students_est, 0) > 0 then 'Starter 899'
                      else 'Growth 1999 (assumed)' end,
               'stage',         l.stage,
               'do_not_contact', l.do_not_contact,
               'owner',         l.owner,
               'last_touch_at', l.last_touch_at,
               'next_action_on', l.next_action_on,
               'touch_count',   (select count(*) from sales.touches t
                                  where t.lead_id = l.id),
               'last_outcome',  (select t.outcome from sales.touches t
                                  where t.lead_id = l.id
                                  order by t.occurred_at desc limit 1),
               -- click-to-chat. Text only: wa.me cannot carry the flyer,
               -- which has to be attached by hand in the Business app.
               'wa_link',       case when l.phone is not null
                                     and not l.do_not_contact
                                then 'https://wa.me/91' || l.phone
                                else null end
             ) as obj
        from sales.leads l
       where (p_stage    is null or l.stage = p_stage)
         and (p_sport    is null or l.sport ilike '%' || p_sport || '%')
         and (p_priority is null or p_priority =
               case when l.score >= 8 then 'A'
                    when l.score >= 6 then 'B' else 'C' end)
         and (p_callable is null or p_callable = (
               l.phone is not null
               and l.phone_confidence in ('verified', 'directory')
               and not l.do_not_contact))
         and (p_search is null or p_search = '' or
              l.name  ilike '%' || p_search || '%' or
              coalesce(l.area, '')  ilike '%' || p_search || '%' or
              coalesce(l.phone, '') ilike '%' || p_search || '%')
       order by l.score desc, ord_conf, lower(l.name)
       limit greatest(1, least(coalesce(p_limit, 200), 1000))
      offset greatest(0, coalesce(p_offset, 0))
    ) q;

  return result;
end $$;

-- Bulk import. Idempotent on import_key, and honours the DNC list.
create or replace function public.sales_import(p_rows jsonb)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  r          jsonb;
  v_key      text;
  v_phone    text;
  v_conf     text;
  n_ins      int := 0;
  n_upd      int := 0;
  n_dnc      int := 0;
  n_nophone  int := 0;
  existed    boolean;
begin
  perform assert_operator();

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    -- normalised name is the identity of a lead
    v_key := regexp_replace(
               lower(coalesce(r->>'name', '')), '[^a-z0-9]+', '', 'g');
    if v_key = '' then
      continue;
    end if;

    v_phone := sales.norm_phone(r->>'phone');
    v_conf  := coalesce(nullif(r->>'phone_confidence', ''), 'none');

    -- A number we could not normalise is not callable. Say so rather than
    -- storing it as if it were.
    if v_phone is null and coalesce(r->>'phone', '') <> '' then
      v_conf := 'malformed';
    elsif v_phone is null then
      v_conf := 'none';
      n_nophone := n_nophone + 1;
    end if;

    if v_conf not in ('verified', 'directory', 'malformed', 'none') then
      v_conf := 'none';
    end if;

    select exists (select 1 from sales.leads where import_key = v_key)
      into existed;

    insert into sales.leads as l (
      import_key, name, contact_name, sport, area, city,
      phone, phone_confidence, phone_source_url, website_or_social,
      branches, students_est, fees_seen, tech_signal,
      coaching_evidence, size_signal, notes,
      do_not_contact
    ) values (
      v_key,
      r->>'name',
      nullif(r->>'contact_name', ''),
      nullif(r->>'sport', ''),
      nullif(r->>'area', ''),
      coalesce(nullif(r->>'city', ''), 'Hyderabad'),
      v_phone,
      v_conf,
      nullif(r->>'phone_source_url', ''),
      nullif(r->>'website_or_social', ''),
      greatest(1, coalesce((r->>'branches')::int, 1)),
      nullif(r->>'students_est', '')::int,
      nullif(r->>'fees_seen', ''),
      nullif(r->>'tech_signal', ''),
      nullif(r->>'coaching_evidence', ''),
      nullif(r->>'size_signal', ''),
      nullif(r->>'notes', ''),
      -- suppressed on the way in if the number is on the DNC list
      v_phone is not null
        and exists (select 1 from sales.dnc d where d.phone = v_phone)
    )
    on conflict (import_key) do update set
      -- Never downgrade a better phone with a worse one, and never
      -- overwrite a human's stage/owner/notes with CSV values.
      phone = case
                when excluded.phone is null then l.phone
                when l.phone is null then excluded.phone
                when excluded.phone_confidence = 'verified'
                     and l.phone_confidence <> 'verified' then excluded.phone
                else l.phone end,
      phone_confidence = case
                when excluded.phone is null then l.phone_confidence
                when l.phone is null then excluded.phone_confidence
                when excluded.phone_confidence = 'verified'
                     and l.phone_confidence <> 'verified'
                  then excluded.phone_confidence
                else l.phone_confidence end,
      phone_source_url  = coalesce(
                            case when excluded.phone_confidence = 'verified'
                                   and l.phone_confidence <> 'verified'
                                 then excluded.phone_source_url end,
                            l.phone_source_url, excluded.phone_source_url),
      contact_name      = coalesce(l.contact_name, excluded.contact_name),
      area              = coalesce(l.area, excluded.area),
      website_or_social = coalesce(l.website_or_social,
                                   excluded.website_or_social),
      branches          = greatest(l.branches, excluded.branches),
      students_est      = coalesce(greatest(l.students_est,
                                            excluded.students_est),
                                   excluded.students_est, l.students_est),
      fees_seen         = coalesce(l.fees_seen, excluded.fees_seen),
      tech_signal       = coalesce(l.tech_signal, excluded.tech_signal),
      coaching_evidence = coalesce(l.coaching_evidence,
                                   excluded.coaching_evidence),
      size_signal       = coalesce(l.size_signal, excluded.size_signal),
      sport             = case
                            when l.sport is null then excluded.sport
                            when excluded.sport is null then l.sport
                            when l.sport ilike '%' || excluded.sport || '%'
                              then l.sport
                            else l.sport || ' / ' || excluded.sport end,
      -- a DNC number stays suppressed no matter what the CSV says
      do_not_contact    = l.do_not_contact or excluded.do_not_contact;

    if existed then n_upd := n_upd + 1; else n_ins := n_ins + 1; end if;
  end loop;

  select count(*) into n_dnc
    from sales.leads where do_not_contact;

  return jsonb_build_object(
    'inserted', n_ins,
    'updated',  n_upd,
    'suppressed_dnc', n_dnc,
    'without_phone', n_nophone,
    'total', (select count(*) from sales.leads));
end $$;

-- Record an outreach attempt, and move the stage on.
create or replace function public.sales_log_touch(
  p_lead      uuid,
  p_channel   text,
  p_outcome   text default 'sent',
  p_direction text default 'out',
  p_template  text default null,
  p_body      text default null,
  p_sent_from text default null,
  p_notes     text default null,
  p_next_on   date default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  v_lead  sales.leads;
  v_stage text;
begin
  perform assert_operator();

  select * into v_lead from sales.leads where id = p_lead;
  if not found then
    raise exception 'no such lead %', p_lead;
  end if;

  -- The whole point of a do-not-contact list is that it refuses.
  if v_lead.do_not_contact and p_direction = 'out' then
    raise exception
      'lead % is do-not-contact; outbound touches are refused', v_lead.name;
  end if;

  insert into sales.touches (lead_id, channel, direction, template, body,
                             outcome, sent_from, notes)
  values (p_lead, p_channel, coalesce(p_direction, 'out'), p_template,
          p_body, coalesce(p_outcome, 'sent'), p_sent_from, p_notes);

  -- Stage machine. Deliberately one-way for the good outcomes: a later
  -- 'sent' must not drag a replied lead back to contacted.
  v_stage := v_lead.stage;
  if p_outcome = 'not_interested' then
    v_stage := 'lost';
  elsif p_direction = 'in' or p_outcome = 'replied' then
    if v_stage in ('new', 'contacted') then v_stage := 'replied'; end if;
  elsif v_stage = 'new' then
    v_stage := 'contacted';
  end if;

  update sales.leads
     set stage         = v_stage,
         last_touch_at = now(),
         next_action_on = coalesce(p_next_on, next_action_on),
         -- a wrong number is a data fact, not a pipeline stage
         phone_confidence = case when p_outcome = 'wrong_number'
                                 then 'malformed'
                                 else phone_confidence end
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'stage', v_stage,
                            'was', v_lead.stage);
end $$;

create or replace function public.sales_set_stage(
  p_lead   uuid,
  p_stage  text,
  p_tenant text default null,
  p_owner  text default null,
  p_next_on date default null,
  p_notes  text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_before text;
begin
  perform assert_operator();

  select stage into v_before from sales.leads where id = p_lead;
  if not found then raise exception 'no such lead %', p_lead; end if;

  if p_stage = 'won' and p_tenant is null then
    raise exception
      'a won lead must name the tenant it became (p_tenant)';
  end if;

  update sales.leads
     set stage = p_stage,
         converted_tenant_id = coalesce(p_tenant, converted_tenant_id),
         owner = coalesce(p_owner, owner),
         next_action_on = coalesce(p_next_on, next_action_on),
         notes = case when p_notes is null or p_notes = '' then notes
                      else coalesce(notes || E'\n', '') ||
                           to_char(now() at time zone 'Asia/Kolkata',
                                   'YYYY-MM-DD HH24:MI') ||
                           ' IST — ' || p_notes end
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'stage', p_stage, 'was', v_before);
end $$;

-- Do-not-contact. Writes the number to sales.dnc so a re-import cannot
-- bring them back, then suppresses every lead sharing that number.
create or replace function public.sales_set_dnc(
  p_lead   uuid,
  p_reason text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_phone text; v_n int;
begin
  perform assert_operator();

  select phone into v_phone from sales.leads where id = p_lead;
  if not found then raise exception 'no such lead %', p_lead; end if;

  if v_phone is not null then
    insert into sales.dnc (phone, reason, added_by)
    values (v_phone, p_reason,
            coalesce(auth.jwt()->>'email', 'operator'))
    on conflict (phone) do update
      set reason = coalesce(excluded.reason, sales.dnc.reason);

    update sales.leads set do_not_contact = true, stage = 'lost'
     where phone = v_phone;
    select count(*) into v_n from sales.leads where phone = v_phone;
  else
    update sales.leads set do_not_contact = true, stage = 'lost'
     where id = p_lead;
    v_n := 1;
  end if;

  return jsonb_build_object('phone', v_phone, 'leads_suppressed', v_n);
end $$;

-- One lead's full history, for the drawer in the console.
create or replace function public.sales_lead_detail(p_lead uuid)
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare result jsonb;
begin
  perform assert_operator();

  select jsonb_build_object(
    'lead', to_jsonb(l) - 'import_key',
    'priority', case when l.score >= 8 then 'A'
                     when l.score >= 6 then 'B' else 'C' end,
    'wa_link', case when l.phone is not null and not l.do_not_contact
                    then 'https://wa.me/91' || l.phone else null end,
    'touches', (select coalesce(jsonb_agg(jsonb_build_object(
                    'at_ist', to_char(t.occurred_at at time zone 'Asia/Kolkata',
                                      'YYYY-MM-DD HH24:MI'),
                    'channel', t.channel, 'direction', t.direction,
                    'outcome', t.outcome, 'template', t.template,
                    'body', t.body, 'sent_from', t.sent_from,
                    'notes', t.notes) order by t.occurred_at desc), '[]'::jsonb)
                  from sales.touches t where t.lead_id = l.id)
  ) into result
    from sales.leads l where l.id = p_lead;

  if result is null then raise exception 'no such lead %', p_lead; end if;
  return result;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 9. Grants. Default is PUBLIC-executable, so revoke first — and note
--    it is `public`, the pseudo-role, that matters. Revoking anon alone
--    is a no-op (the 0009/0010 lesson).
--    The console signs in as `authenticated` with am_role=operator, so
--    authenticated must keep EXECUTE; assert_operator() in each body is
--    what stops tenant staff, who are also `authenticated`.
-- ─────────────────────────────────────────────────────────────
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.sales_pipeline()',
    'public.sales_leads(text,text,text,text,boolean,int,int)',
    'public.sales_import(jsonb)',
    'public.sales_log_touch(uuid,text,text,text,text,text,text,text,date)',
    'public.sales_set_stage(uuid,text,text,text,date,text)',
    'public.sales_set_dnc(uuid,text)',
    'public.sales_lead_detail(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated, service_role', fn);
  end loop;
end $$;

-- assert_operator and the sales helpers are internal; nothing anonymous
-- should be able to probe them.
revoke execute on function public.assert_operator() from public, anon;
grant  execute on function public.assert_operator() to authenticated, service_role;
revoke execute on function sales.lead_score(int,int,text,text,text,text)
  from public, anon;
revoke execute on function sales.norm_phone(text) from public, anon;

-- ─────────────────────────────────────────────────────────────
-- 10. Prove the lockdown in the migration, so it is re-checked every
--     time this file is replayed. Reasoning is not evidence — 0010 was
--     argued correctly and would still have published every parent's
--     phone number.
-- ─────────────────────────────────────────────────────────────
do $$
declare n int;
begin
  -- anon must not be able to execute any sales entry point
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    raise exception 'anon can execute % sales function(s)', n;
  end if;

  -- anon and authenticated must not reach the tables directly
  select count(*) into n
    from information_schema.role_table_grants
   where table_schema = 'sales'
     and grantee in ('anon', 'authenticated', 'PUBLIC');
  if n > 0 then
    raise exception 'sales tables carry % grant(s) to anon/authenticated/PUBLIC', n;
  end if;

  -- RLS on, and no policies: owner-only
  select count(*) into n
    from pg_tables where schemaname = 'sales' and not rowsecurity;
  if n > 0 then
    raise exception '% sales table(s) without RLS', n;
  end if;

  -- the scoring function must actually be immutable, or the generated
  -- column silently is not what this file claims
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sales' and p.proname = 'lead_score'
     and p.provolatile <> 'i';
  if n > 0 then
    raise exception 'sales.lead_score is not IMMUTABLE';
  end if;

  raise notice 'sales pipeline locked down: anon has no reach, RLS on, score immutable';
end $$;
