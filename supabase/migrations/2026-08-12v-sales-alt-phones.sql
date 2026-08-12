-- Alternate numbers for a sales lead.
--
-- WHY, and why now
--
-- 15 of the 125 researched leads published more than one number — a
-- Splash-In field reads "+91 82 9797 2929 / 99121 22250", SR Swimming
-- publishes one mobile per branch, Sreenidhi lists three admissions
-- lines. Keeping only the first throws away the retry, and on this list
-- 47 of the numbers are directory-sourced with an expected low connect
-- rate. A second number is the cheapest possible recovery.
--
-- Added as its own column rather than stuffed into notes because
-- sales_set_dnc() has to be able to search it — see below. Applied while
-- sales.leads is still empty, so there is no data to migrate.
--
-- THE CORRECTNESS POINT THIS FIXES
--
-- If someone tells us to stop on their second number, suppressing only
-- rows whose PRIMARY matches leaves them reachable. sales_set_dnc() and
-- sales_import() therefore both match against primary OR alternates.
-- A do-not-contact list with a gap in it is not a do-not-contact list.
--
-- Scope: shared. Operator-only, same as 2026-08-12u.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

alter table sales.leads
  add column if not exists alt_phones text[] not null default '{}';

comment on column sales.leads.alt_phones is
  'Further published numbers, normalised to 10 digits. Searched by '
  'sales_set_dnc() so a stop request on any of a lead''s numbers '
  'suppresses the lead.';

create index if not exists leads_alt_phones
  on sales.leads using gin (alt_phones);

-- ─────────────────────────────────────────────────────────────
-- sales_import: accept alt_phones, and check DNC against every number
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_import(p_rows jsonb)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  r         jsonb;
  v_key     text;
  v_phone   text;
  v_conf    text;
  v_alts    text[];
  v_all     text[];
  n_ins     int := 0;
  n_upd     int := 0;
  n_dnc     int := 0;
  n_nophone int := 0;
  existed   boolean;
begin
  perform assert_operator();

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_key := regexp_replace(
               lower(coalesce(r->>'name', '')), '[^a-z0-9]+', '', 'g');
    if v_key = '' then continue; end if;

    v_phone := sales.norm_phone(r->>'phone');
    v_conf  := coalesce(nullif(r->>'phone_confidence', ''), 'none');

    -- alternates: normalise each, drop anything unrecognisable rather
    -- than storing a number nobody can call
    select coalesce(array_agg(distinct m) filter (where m is not null), '{}')
      into v_alts
      from (select sales.norm_phone(x) as m
              from jsonb_array_elements_text(
                     case when jsonb_typeof(coalesce(r->'alt_phones','[]'::jsonb))
                               = 'array'
                          then r->'alt_phones' else '[]'::jsonb end) as x) s
     where m is distinct from v_phone;

    if v_phone is null and coalesce(r->>'phone', '') <> '' then
      v_conf := 'malformed';
    elsif v_phone is null then
      v_conf := 'none';
      n_nophone := n_nophone + 1;
    end if;
    if v_conf not in ('verified','directory','malformed','none') then
      v_conf := 'none';
    end if;

    -- every number this lead is reachable on
    v_all := array_remove(v_alts || array[v_phone], null);

    select exists (select 1 from sales.leads where import_key = v_key)
      into existed;

    insert into sales.leads as l (
      import_key, name, contact_name, sport, area, city,
      phone, alt_phones, phone_confidence, phone_source_url,
      website_or_social, branches, students_est, fees_seen, tech_signal,
      coaching_evidence, size_signal, notes, do_not_contact
    ) values (
      v_key, r->>'name',
      nullif(r->>'contact_name',''), nullif(r->>'sport',''),
      nullif(r->>'area',''), coalesce(nullif(r->>'city',''), 'Hyderabad'),
      v_phone, v_alts, v_conf,
      nullif(r->>'phone_source_url',''), nullif(r->>'website_or_social',''),
      greatest(1, coalesce((r->>'branches')::int, 1)),
      nullif(r->>'students_est','')::int,
      nullif(r->>'fees_seen',''), nullif(r->>'tech_signal',''),
      nullif(r->>'coaching_evidence',''), nullif(r->>'size_signal',''),
      nullif(r->>'notes',''),
      -- suppressed on the way in if ANY of its numbers said stop
      exists (select 1 from sales.dnc d where d.phone = any(v_all))
    )
    on conflict (import_key) do update set
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
      phone_source_url = coalesce(
                           case when excluded.phone_confidence = 'verified'
                                  and l.phone_confidence <> 'verified'
                                then excluded.phone_source_url end,
                           l.phone_source_url, excluded.phone_source_url),
      -- union the alternates, minus whatever is now the primary
      alt_phones = array_remove(
                     (select coalesce(array_agg(distinct e), '{}')
                        from unnest(l.alt_phones || excluded.alt_phones) e
                       where e is distinct from coalesce(
                               case when excluded.phone_confidence = 'verified'
                                      and l.phone_confidence <> 'verified'
                                    then excluded.phone else l.phone end,
                               l.phone)),
                     null),
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
      notes             = coalesce(l.notes, excluded.notes),
      sport             = case
                            when l.sport is null then excluded.sport
                            when excluded.sport is null then l.sport
                            when l.sport ilike '%' || excluded.sport || '%'
                              then l.sport
                            else l.sport || ' / ' || excluded.sport end,
      do_not_contact    = l.do_not_contact or excluded.do_not_contact;

    if existed then n_upd := n_upd + 1; else n_ins := n_ins + 1; end if;
  end loop;

  select count(*) into n_dnc from sales.leads where do_not_contact;

  return jsonb_build_object(
    'inserted', n_ins, 'updated', n_upd,
    'suppressed_dnc', n_dnc, 'without_phone', n_nophone,
    'total', (select count(*) from sales.leads));
end $$;

-- ─────────────────────────────────────────────────────────────
-- sales_set_dnc: match on any of the lead's numbers
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_set_dnc(
  p_lead   uuid,
  p_reason text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_all text[]; v_n int;
begin
  perform assert_operator();

  select array_remove(alt_phones || array[phone], null) into v_all
    from sales.leads where id = p_lead;
  if not found then raise exception 'no such lead %', p_lead; end if;

  if array_length(v_all, 1) > 0 then
    insert into sales.dnc (phone, reason, added_by)
    select x, p_reason, coalesce(auth.jwt()->>'email', 'operator')
      from unnest(v_all) x
    on conflict (phone) do update
      set reason = coalesce(excluded.reason, sales.dnc.reason);

    -- suppress every lead reachable on any of those numbers
    update sales.leads
       set do_not_contact = true, stage = 'lost'
     where phone = any(v_all)
        or alt_phones && v_all;
    select count(*) into v_n from sales.leads
     where phone = any(v_all) or alt_phones && v_all;
  else
    update sales.leads set do_not_contact = true, stage = 'lost'
     where id = p_lead;
    v_n := 1;
  end if;

  return jsonb_build_object('numbers', v_all, 'leads_suppressed', v_n);
end $$;

-- ─────────────────────────────────────────────────────────────
-- sales_leads: surface the alternates to the console
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
               'phone', l.phone,
               'alt_phones', to_jsonb(l.alt_phones),
               'phone_confidence', l.phone_confidence,
               'phone_source_url', l.phone_source_url,
               'website_or_social', l.website_or_social,
               'branches', l.branches, 'students_est', l.students_est,
               'fees_seen', l.fees_seen, 'tech_signal', l.tech_signal,
               'notes', l.notes, 'score', l.score,
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

-- Grants are per-signature and these signatures are unchanged, so the
-- 2026-08-12u grants still apply. Re-assert anyway: `create or replace`
-- keeps existing ACLs, but a future signature change would silently
-- reopen the default PUBLIC grant, and that is the 0010 lesson.
revoke execute on function public.sales_import(jsonb) from public, anon;
revoke execute on function public.sales_set_dnc(uuid, text) from public, anon;
revoke execute on function
  public.sales_leads(text,text,text,text,boolean,int,int) from public, anon;
grant execute on function public.sales_import(jsonb)
  to authenticated, service_role;
grant execute on function public.sales_set_dnc(uuid, text)
  to authenticated, service_role;
grant execute on function
  public.sales_leads(text,text,text,text,boolean,int,int)
  to authenticated, service_role;

do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    raise exception 'anon can execute % sales function(s)', n;
  end if;
  raise notice 'alt_phones added; anon still has no reach';
end $$;
