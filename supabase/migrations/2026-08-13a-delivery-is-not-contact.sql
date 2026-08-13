-- A message that never arrived is not a contact attempt.
--
-- WHY THIS MATTERS NOW
--
-- 15+ openers went out and not one reply came back. Before touching the copy
-- there is a cheaper explanation to rule out: 57 of the 112 callable numbers
-- on this list are `directory` confidence — scraped from listing aggregators,
-- where a call-tracking line with no WhatsApp behind it is common. CR Tennis
-- was exactly that.
--
-- WhatsApp already shows which happened: one tick means never delivered, two
-- means delivered, blue means read. That is the difference between "the list
-- is wrong" and "the message is wrong", and they call for opposite fixes. But
-- there was no way to record it, so the distinction was being thrown away.
--
-- WHAT CHANGES
--
-- `failed` already existed in the outcome constraint but behaved wrongly: it
-- fell through to the default branch and advanced the lead to 'contacted'.
-- Nobody was contacted. Now:
--
--   · 'failed' leaves the stage alone, like 'opened' — nothing reached them
--   · it downgrades phone_confidence to 'malformed', so the number stops
--     counting as callable and stops inflating the reachable total
--   · sales_ab_results() excludes undelivered sends from the denominator,
--     because a message that did not arrive cannot earn a reply and would
--     drag both arms' rates down toward zero
--
-- That last one is the point. Without it the experiment measures the quality
-- of a scraped phone list, not the difference between the two openers.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

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
  v_out   text;
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

  v_out := coalesce(p_outcome, 'sent');

  insert into sales.touches (lead_id, channel, direction, template, body,
                             outcome, sent_from, notes, variant)
  values (p_lead, p_channel, coalesce(p_direction, 'out'), p_template,
          p_body, v_out, p_sent_from, p_notes,
          coalesce(p_variant, v_lead.variant));

  v_stage := v_lead.stage;
  if v_out = 'not_interested' then
    v_stage := 'lost';
  elsif p_direction = 'in' or v_out = 'replied' then
    if v_stage in ('new', 'contacted') then v_stage := 'replied'; end if;
  elsif v_out in ('opened', 'failed') then
    -- a draft is not an attempt, and neither is a message that never landed
    null;
  elsif v_stage = 'new' then
    v_stage := 'contacted';
  end if;

  update sales.leads
     set stage = v_stage,
         last_touch_at = case when v_out in ('opened', 'failed')
                              then last_touch_at else now() end,
         next_action_on = coalesce(p_next_on, next_action_on),
         -- an undelivered number is not a callable number: stop it counting
         phone_confidence = case
                              when v_out = 'wrong_number' then 'malformed'
                              when v_out = 'failed'       then 'malformed'
                              else phone_confidence end
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'stage', v_stage,
                            'was', v_lead.stage, 'variant', v_lead.variant,
                            'outcome', v_out);
end $$;

-- ─────────────────────────────────────────────────────────────
-- The denominator must count messages that ARRIVED
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_ab_results()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  a_sent int; a_rep int; b_sent int; b_rep int;
  a_draft int; b_draft int; a_fail int; b_fail int;
  a_rate numeric; b_rate numeric; pooled numeric; se numeric; z numeric;
  mde numeric; verdict text;
begin
  perform assert_operator();

  /* DELIVERED attempts only. A lead is counted once, and only if it has an
     outbound touch that is neither a draft nor a known delivery failure.
     Counting undelivered sends would measure the scraped phone list rather
     than the two openers. */
  select count(distinct t.lead_id) into a_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and t.outcome not in ('opened', 'failed')
     and l.variant = 'A'
     and not exists (select 1 from sales.touches f
                      where f.lead_id = t.lead_id and f.outcome = 'failed');
  select count(distinct t.lead_id) into b_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and t.outcome not in ('opened', 'failed')
     and l.variant = 'B'
     and not exists (select 1 from sales.touches f
                      where f.lead_id = t.lead_id and f.outcome = 'failed');

  select count(distinct t.lead_id) into a_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and l.variant = 'A';
  select count(distinct t.lead_id) into b_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and l.variant = 'B';

  select count(distinct t.lead_id) into a_fail from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'failed' and l.variant = 'A';
  select count(distinct t.lead_id) into b_fail from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'failed' and l.variant = 'B';

  select count(distinct t.lead_id) into a_rep from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.variant = 'A' and (t.direction = 'in' or t.outcome = 'replied');
  select count(distinct t.lead_id) into b_rep from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.variant = 'B' and (t.direction = 'in' or t.outcome = 'replied');

  a_rate := case when a_sent > 0 then a_rep::numeric / a_sent end;
  b_rate := case when b_sent > 0 then b_rep::numeric / b_sent end;

  if a_sent >= 10 and b_sent >= 10 then
    pooled := (a_rep + b_rep)::numeric / (a_sent + b_sent);
    se := sqrt(greatest(pooled * (1 - pooled)
               * (1.0 / a_sent + 1.0 / b_sent), 1e-12));
    z := case when se > 0 then (b_rate - a_rate) / se end;
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
    verdict := format('too early — need 10 DELIVERED per arm (A=%s, B=%s)',
                      a_sent, b_sent);
  end if;

  return jsonb_build_object(
    'A', jsonb_build_object('label', 'text only',
           'assigned', (select count(*) from sales.leads
                         where variant = 'A' and not do_not_contact),
           'sent', a_sent, 'drafted', a_draft, 'undelivered', a_fail,
           'replied', a_rep,
           'reply_rate_pct', round(coalesce(a_rate, 0) * 100, 1)),
    'B', jsonb_build_object('label', 'text + one screenshot',
           'assigned', (select count(*) from sales.leads
                         where variant = 'B' and not do_not_contact),
           'sent', b_sent, 'drafted', b_draft, 'undelivered', b_fail,
           'replied', b_rep,
           'reply_rate_pct', round(coalesce(b_rate, 0) * 100, 1)),
    'difference_pct', round((coalesce(b_rate,0) - coalesce(a_rate,0)) * 100, 1),
    'min_detectable_pct', mde,
    'z', round(coalesce(z, 0), 2),
    'undelivered_total', a_fail + b_fail,
    'verdict', verdict);
end $$;

revoke execute on function public.sales_log_touch(
  uuid,text,text,text,text,text,text,text,date,text) from public, anon;
grant  execute on function public.sales_log_touch(
  uuid,text,text,text,text,text,text,text,date,text)
  to authenticated, service_role;
revoke execute on function public.sales_ab_results() from public, anon;
grant  execute on function public.sales_ab_results()
  to authenticated, service_role;

do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then raise exception 'anon can execute % sales function(s)', n; end if;

  -- the new key must be present, or the console cannot show it
  if (sales_ab_results()->'A'->>'undelivered') is null then
    raise exception 'sales_ab_results does not report undelivered';
  end if;
  raise notice 'undelivered sends no longer count as contact or as denominator';
end $$;
