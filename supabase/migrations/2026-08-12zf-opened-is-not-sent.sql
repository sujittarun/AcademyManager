-- Clicking WhatsApp is not sending a WhatsApp.
--
-- WHAT WAS WRONG
--
-- The console's WhatsApp button opened wa.me AND logged outcome 'sent' in the
-- same click. But the send is manual — the caller still has to press send in
-- WhatsApp, and may well read the draft and close it. So merely LOOKING at a
-- prospect's opener marked them contacted, advanced their stage out of 'new',
-- and counted them in the A/B denominator.
--
-- Caught because the owner clicked three drafts to read them, sent nothing,
-- and the pipeline reported A=2 B=1 sent with three leads at 'contacted'.
-- Those leads would then have been skipped as already-worked.
--
-- It also biases the experiment in the worst direction: the denominator
-- counts drafts and the numerator counts real replies, so both arms' reply
-- rates read low, and the arm whose drafts are more often abandoned looks
-- worse for a reason that has nothing to do with the screenshot.
--
-- THE FIX
--
-- Record what actually happened. Opening a draft is a real, useful fact —
-- it says "I have this one queued" — so it gets its own outcome, 'opened',
-- which does NOT advance the stage and does NOT count as an attempt. Only an
-- explicit 'sent' does, which the console now asks for after the caller
-- returns from WhatsApp.
--
-- Also cleans the four touches already logged and returns those three leads
-- to 'new', because nothing was ever sent to them.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

-- ─────────────────────────────────────────────────────────────
-- 1. 'opened' becomes a real outcome
-- ─────────────────────────────────────────────────────────────
alter table sales.touches drop constraint if exists touches_outcome_check;
alter table sales.touches
  add constraint touches_outcome_check
  check (outcome in ('opened', 'sent', 'delivered', 'read', 'replied',
                     'no_answer', 'wrong_number', 'failed', 'not_interested'));

comment on column sales.touches.outcome is
  '''opened'' means a draft was opened and nothing left our hands — it does '
  'not advance the stage and does not count as an attempt. Everything from '
  '''sent'' onwards does.';

-- ─────────────────────────────────────────────────────────────
-- 2. Undo the four drafts that were logged as sends
-- ─────────────────────────────────────────────────────────────
do $$
declare v_leads uuid[]; n int;
begin
  select array_agg(distinct lead_id) into v_leads from sales.touches;

  delete from sales.touches;
  get diagnostics n = row_count;

  -- nothing was sent to them, so they go back in the queue
  update sales.leads
     set stage = 'new', last_touch_at = null
   where id = any(coalesce(v_leads, '{}'::uuid[]))
     and stage = 'contacted'
     and not do_not_contact;

  raise notice 'removed % draft-as-sent touch(es); affected leads returned to new', n;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 3. Stage advances on a real attempt, never on a draft
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
  elsif v_out = 'opened' then
    -- a draft is not an attempt: leave the stage exactly where it was
    null;
  elsif v_stage = 'new' then
    v_stage := 'contacted';
  end if;

  update sales.leads
     set stage = v_stage,
         -- last_touch_at means "when did we last actually reach out", so a
         -- draft must not move it either
         last_touch_at = case when v_out = 'opened'
                              then last_touch_at else now() end,
         next_action_on = coalesce(p_next_on, next_action_on),
         phone_confidence = case when v_out = 'wrong_number'
                                 then 'malformed' else phone_confidence end
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'stage', v_stage,
                            'was', v_lead.stage, 'variant', v_lead.variant,
                            'outcome', v_out);
end $$;

-- ─────────────────────────────────────────────────────────────
-- 4. The A/B denominator counts attempts, not drafts
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_ab_results()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  a_sent int; a_rep int; b_sent int; b_rep int; a_draft int; b_draft int;
  a_rate numeric; b_rate numeric; pooled numeric; se numeric; z numeric;
  mde numeric; verdict text;
begin
  perform assert_operator();

  -- ATTEMPTS only. 'opened' is excluded on purpose: it means a draft was
  -- looked at, and counting it would deflate both arms' reply rates.
  select count(distinct t.lead_id) into a_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and t.outcome <> 'opened' and l.variant = 'A';
  select count(distinct t.lead_id) into b_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and t.outcome <> 'opened' and l.variant = 'B';

  -- drafts, reported separately so a queue is visible without polluting the rate
  select count(distinct t.lead_id) into a_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and l.variant = 'A';
  select count(distinct t.lead_id) into b_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and l.variant = 'B';

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
    verdict := format('too early — need at least 10 SENT per arm (A=%s, B=%s)',
                      a_sent, b_sent);
  end if;

  return jsonb_build_object(
    'A', jsonb_build_object('label', 'text only',
           'assigned', (select count(*) from sales.leads
                         where variant = 'A' and not do_not_contact),
           'sent', a_sent, 'drafted', a_draft, 'replied', a_rep,
           'reply_rate_pct', round(coalesce(a_rate, 0) * 100, 1)),
    'B', jsonb_build_object('label', 'text + one screenshot',
           'assigned', (select count(*) from sales.leads
                         where variant = 'B' and not do_not_contact),
           'sent', b_sent, 'drafted', b_draft, 'replied', b_rep,
           'reply_rate_pct', round(coalesce(b_rate, 0) * 100, 1)),
    'difference_pct', round((coalesce(b_rate,0) - coalesce(a_rate,0)) * 100, 1),
    'min_detectable_pct', mde,
    'z', round(coalesce(z, 0), 2),
    'verdict', verdict);
end $$;

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

-- ─────────────────────────────────────────────────────────────
-- 5. Assertions
-- ─────────────────────────────────────────────────────────────
do $$
declare r jsonb; n int; v_lead uuid; v_stage text;
begin
  -- the false sends are gone and nobody is stuck at 'contacted'
  select count(*) into n from sales.touches;
  if n <> 0 then raise exception '% touch(es) survived the cleanup', n; end if;
  select count(*) into n from sales.leads
   where stage <> 'new' and not do_not_contact;
  if n > 0 then
    raise exception '% lead(s) are still past new with no touches', n;
  end if;

  -- a draft must not advance the stage
  select id into v_lead from sales.leads
   where phone is not null and not do_not_contact order by id limit 1;
  r := sales_log_touch(v_lead, 'whatsapp', 'opened', 'out');
  if r->>'stage' <> 'new' then
    raise exception 'opening a draft advanced the stage to %', r->>'stage';
  end if;
  if not (select last_touch_at is null from sales.leads where id = v_lead) then
    raise exception 'opening a draft moved last_touch_at';
  end if;

  -- and it must not count as an attempt
  r := sales_ab_results();
  if (r->'A'->>'sent')::int + (r->'B'->>'sent')::int <> 0 then
    raise exception 'a draft was counted as sent';
  end if;
  if (r->'A'->>'drafted')::int + (r->'B'->>'drafted')::int <> 1 then
    raise exception 'the draft was not reported as drafted';
  end if;

  -- an actual send does advance
  r := sales_log_touch(v_lead, 'whatsapp', 'sent', 'out');
  if r->>'stage' <> 'contacted' then
    raise exception 'a real send did not advance the stage (got %)', r->>'stage';
  end if;
  r := sales_ab_results();
  if (r->'A'->>'sent')::int + (r->'B'->>'sent')::int <> 1 then
    raise exception 'a real send was not counted';
  end if;

  raise notice 'opened != sent: drafts no longer advance the stage or count as attempts';
end $$;
