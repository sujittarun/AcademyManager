-- A/B test the opener: does a screenshot in the first burst earn replies?
--
-- WHAT IS BEING TESTED, AND WHY ONLY ONE THING
--
-- 112 callable leads split two ways is ~56 per arm. At an expected 15-30%
-- reply rate that is 8-17 replies per arm, which can only resolve a LARGE
-- difference -- roughly 15 percentage points or more. Testing two similar
-- wordings against each other would produce a number that looks like an
-- answer and is noise. So both arms send the SAME copy, and the only
-- difference is structural:
--
--   A = text only
--   B = the same text, then one screenshot of the dues list
--
-- sales_ab_results() reports the minimum detectable effect alongside the
-- rates, so nobody reads a 3-point gap as a finding.
--
-- WHY THE ASSIGNMENT IS A GENERATED COLUMN
--
-- The arm a lead belongs to must be identical in the console, in a manual
-- query and in the results function, and it must never change once that
-- lead has been messaged -- an experiment that reassigns its subjects
-- measures nothing. So it is derived from the lead's own id by an
-- IMMUTABLE expression and STORED. There is no code path that can write a
-- different one, and no way for a re-import to reshuffle the arms.
--
-- md5's first hex character is uniform over 0-9a-f, and exactly 8 of those
-- 16 characters have an even ASCII value, so the split is even by
-- construction rather than by luck.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

alter table sales.leads
  add column if not exists variant text
    generated always as (
      case when mod(ascii(substr(md5(id::text), 1, 1)), 2) = 0
           then 'A' else 'B' end
    ) stored;

comment on column sales.leads.variant is
  'A/B arm, derived from the lead id and STORED so it can never be '
  'reassigned. A = text-only opener, B = opener plus one screenshot.';

-- Which arm a touch was actually sent under. A separate column rather than
-- parsing it back out of `template`: measurement that depends on string
-- shape breaks the first time someone edits a template name.
alter table sales.touches
  add column if not exists variant text;

comment on column sales.touches.variant is
  'The arm this touch was sent under, recorded at send time. Never inferred '
  'from the lead afterwards -- the whole point is to measure what was sent.';

create index if not exists touches_variant
  on sales.touches (variant, direction, outcome);

-- ─────────────────────────────────────────────────────────────
-- log a touch, now recording the arm
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_log_touch(
  p_lead      uuid,
  p_channel   text,
  p_outcome   text default 'sent',
  p_direction text default 'out',
  p_template  text default null,
  p_body      text default null,
  p_sent_from text default null,
  p_notes     text default null,
  p_next_on   date default null,
  p_variant   text default null
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

  if v_lead.do_not_contact and p_direction = 'out' then
    raise exception
      'lead % is do-not-contact; outbound touches are refused', v_lead.name;
  end if;

  insert into sales.touches (lead_id, channel, direction, template, body,
                             outcome, sent_from, notes, variant)
  values (p_lead, p_channel, coalesce(p_direction, 'out'), p_template,
          p_body, coalesce(p_outcome, 'sent'), p_sent_from, p_notes,
          -- default to the lead's own arm, so a caller cannot accidentally
          -- log a send against the wrong side of the experiment
          coalesce(p_variant, v_lead.variant));

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
         phone_confidence = case when p_outcome = 'wrong_number'
                                 then 'malformed' else phone_confidence end
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'stage', v_stage,
                            'was', v_lead.stage, 'variant', v_lead.variant);
end $$;

-- ─────────────────────────────────────────────────────────────
-- results, with the honesty built in
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_ab_results()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  a_sent int; a_rep int; b_sent int; b_rep int;
  a_rate numeric; b_rate numeric; pooled numeric; se numeric; z numeric;
  mde numeric; verdict text;
begin
  perform assert_operator();

  -- one outbound opener per lead per arm; a lead chased three times is
  -- still one subject, or the denominator inflates and every rate falls
  select count(distinct t.lead_id) into a_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and l.variant = 'A';
  select count(distinct t.lead_id) into b_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and l.variant = 'B';

  select count(distinct t.lead_id) into a_rep from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.variant = 'A' and (t.direction = 'in' or t.outcome = 'replied');
  select count(distinct t.lead_id) into b_rep from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.variant = 'B' and (t.direction = 'in' or t.outcome = 'replied');

  a_rate := case when a_sent > 0 then a_rep::numeric / a_sent end;
  b_rate := case when b_sent > 0 then b_rep::numeric / b_sent end;

  -- two-proportion z, and the effect this sample could actually resolve
  if a_sent >= 10 and b_sent >= 10 then
    pooled := (a_rep + b_rep)::numeric / (a_sent + b_sent);
    se := sqrt(greatest(pooled * (1 - pooled)
               * (1.0 / a_sent + 1.0 / b_sent), 1e-12));
    z := case when se > 0 then (b_rate - a_rate) / se end;
    -- 1.96 * SE at the observed pooled rate: the smallest gap that would
    -- read as real here. Quoted so a 3-point difference is not celebrated.
    mde := round(1.96 * se * 100, 1);
    verdict := case
      when abs(z) >= 1.96 then
        case when z > 0 then 'B wins — the screenshot earns replies'
             else 'A wins — the screenshot suppresses replies' end
      when abs(z) >= 1.28 then
        case when z > 0 then 'B leads, not yet conclusive — keep sending'
             else 'A leads, not yet conclusive — keep sending' end
      else 'no detectable difference at this sample size' end;
  else
    verdict := format('too early — need at least 10 sent per arm (A=%s, B=%s)',
                      a_sent, b_sent);
  end if;

  return jsonb_build_object(
    'A', jsonb_build_object('label', 'text only',
           'assigned', (select count(*) from sales.leads where variant = 'A'
                          and not do_not_contact),
           'sent', a_sent, 'replied', a_rep,
           'reply_rate_pct', round(coalesce(a_rate, 0) * 100, 1)),
    'B', jsonb_build_object('label', 'text + one screenshot',
           'assigned', (select count(*) from sales.leads where variant = 'B'
                          and not do_not_contact),
           'sent', b_sent, 'replied', b_rep,
           'reply_rate_pct', round(coalesce(b_rate, 0) * 100, 1)),
    'difference_pct', round((coalesce(b_rate, 0) - coalesce(a_rate, 0)) * 100, 1),
    'min_detectable_pct', mde,
    'z', round(coalesce(z, 0), 2),
    'verdict', verdict);
end $$;

-- ─────────────────────────────────────────────────────────────
-- surface the arm to the console
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
               'notes', l.notes, 'score', l.score,
               'variant', l.variant,
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
-- Grants. sales_log_touch gained a parameter, so it is a NEW signature and
-- the old grant does not cover it — a new function is PUBLIC-executable
-- until revoked, and revoking `anon` alone is a no-op. This is exactly the
-- 0010 hole.
-- ─────────────────────────────────────────────────────────────
drop function if exists public.sales_log_touch(
  uuid, text, text, text, text, text, text, text, date);

revoke execute on function public.sales_log_touch(
  uuid,text,text,text,text,text,text,text,date,text) from public, anon;
grant  execute on function public.sales_log_touch(
  uuid,text,text,text,text,text,text,text,date,text)
  to authenticated, service_role;

revoke execute on function public.sales_ab_results() from public, anon;
grant  execute on function public.sales_ab_results()
  to authenticated, service_role;

revoke execute on function
  public.sales_leads(text,text,text,text,boolean,int,int) from public, anon;
grant  execute on function
  public.sales_leads(text,text,text,text,boolean,int,int)
  to authenticated, service_role;

do $$
declare n int; a int; b int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    raise exception 'anon can execute % sales function(s)', n;
  end if;

  -- the split must actually be a split, not 90/10
  select count(*) filter (where variant = 'A'),
         count(*) filter (where variant = 'B') into a, b from sales.leads;
  if a + b > 0 and (least(a, b)::numeric / (a + b)) < 0.35 then
    raise exception 'A/B split is lopsided: A=% B=%', a, b;
  end if;
  raise notice 'A/B wired: A=% B=%; anon still has no reach', a, b;
end $$;
