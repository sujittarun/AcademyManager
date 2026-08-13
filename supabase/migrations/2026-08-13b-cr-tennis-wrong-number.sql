-- CR Tennis was never asked to stop — the number simply has no WhatsApp.
--
-- WHAT WAS WRONG
--
-- On 2026-08-12 the console's only way to take a bad number out of the queue
-- was "Stop", which writes the lead AND every one of its numbers to
-- sales.dnc with reason 'asked us to stop'. So a directory-scraped number
-- with no WhatsApp behind it got recorded as a prospect who refused us.
--
-- Those are opposite facts. A refusal is permanent and must survive a
-- re-import; a wrong number is a data-quality problem that a better number
-- fixes. Recording one as the other loses a live prospect and overstates how
-- many academies said no.
--
-- WHAT THIS ALSO FIXES
--
-- 2026-08-13a established that a message which never arrived is not a contact
-- attempt: 'failed' stops advancing the stage and leaves the A/B denominator
-- alone. 'wrong_number' is the same fact — nothing reached anybody — but it
-- was left behind: it still advanced 'new' to 'contacted' and still counted as
-- a delivered send. Both are corrected here, so the rule holds for every
-- outcome that means "not delivered" rather than for the two I happened to
-- think of first.
--
-- SportsCult Sports Academy (9502729320) is ALSO suppressed as 'asked us to
-- stop' with ZERO outbound touches, which cannot be true either. It is
-- deliberately NOT touched here — the owner has not said what happened, and
-- guessing at a suppression is how a real refusal gets undone. Flagged, not
-- fixed.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

-- ─────────────────────────────────────────────────────────────
-- 1. "not delivered" is one rule, not a list of special cases
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_undelivered(p_outcome text)
returns boolean language sql immutable as $$
  /* Outcomes where nothing reached the prospect. They must not advance the
     stage and must not sit in the A/B denominator, because a message that did
     not arrive cannot earn a reply. 'opened' is a draft we never sent;
     'failed' is one tick; 'wrong_number' is no WhatsApp on that number. */
  select coalesce(p_outcome, '') in ('opened', 'failed', 'wrong_number')
$$;

revoke execute on function public.sales_undelivered(text) from public, anon;
grant  execute on function public.sales_undelivered(text)
  to authenticated, service_role;

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
  elsif sales_undelivered(v_out) then
    -- nothing reached them, so nothing about their stage has changed
    null;
  elsif v_stage = 'new' then
    v_stage := 'contacted';
  end if;

  update sales.leads
     set stage = v_stage,
         last_touch_at = case when sales_undelivered(v_out)
                              then last_touch_at else now() end,
         next_action_on = coalesce(p_next_on, next_action_on),
         -- an unreachable number is not a callable number: stop it counting
         phone_confidence = case
                              when v_out in ('wrong_number', 'failed')
                                then 'malformed'
                              else phone_confidence end
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'stage', v_stage,
                            'was', v_lead.stage, 'variant', v_lead.variant,
                            'outcome', v_out);
end $$;

-- ─────────────────────────────────────────────────────────────
-- 2. the denominator counts messages that ARRIVED
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
     outbound touch that reached somebody — no draft, no one-tick failure, no
     wrong number. Counting the rest would measure the quality of a scraped
     phone list rather than the difference between the two openers. */
  select count(distinct t.lead_id) into a_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and not sales_undelivered(t.outcome)
     and l.variant = 'A'
     and not exists (select 1 from sales.touches f
                      where f.lead_id = t.lead_id
                        and f.outcome in ('failed', 'wrong_number'));
  select count(distinct t.lead_id) into b_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and not sales_undelivered(t.outcome)
     and l.variant = 'B'
     and not exists (select 1 from sales.touches f
                      where f.lead_id = t.lead_id
                        and f.outcome in ('failed', 'wrong_number'));

  select count(distinct t.lead_id) into a_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and l.variant = 'A';
  select count(distinct t.lead_id) into b_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and l.variant = 'B';

  select count(distinct t.lead_id) into a_fail from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome in ('failed', 'wrong_number') and l.variant = 'A';
  select count(distinct t.lead_id) into b_fail from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome in ('failed', 'wrong_number') and l.variant = 'B';

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

-- A new function is PUBLIC-executable until revoked, and revoking `anon`
-- alone is a no-op. sales_undelivered is new, so assert rather than assume.
do $$
declare n int; bad text;
begin
  select count(*), string_agg(p.proname, ', ') into n, bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then raise exception 'anon can execute % sales function(s): %', n, bad; end if;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 3. the correction itself — ONE lead, by id, guarded
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_id    uuid := '92ba026b-16ff-44df-9cc3-5a8b4be9cfcf';  -- CR Tennis Academy
  v_phone text := '9676400202';
  v_lead  sales.leads;
  v_other record;
  n       int;
begin
  select * into v_lead from sales.leads where id = v_id;
  if not found then raise exception 'CR Tennis lead % is gone', v_id; end if;

  -- refuse unless the state is exactly what this migration was written for
  if v_lead.name <> 'CR Tennis Academy' then
    raise exception 'lead % is now "%", not CR Tennis', v_id, v_lead.name;
  end if;
  if v_lead.phone <> v_phone then
    raise exception 'CR Tennis phone is now %, expected %', v_lead.phone, v_phone;
  end if;
  if not v_lead.do_not_contact then
    raise exception 'CR Tennis is no longer suppressed — already corrected?';
  end if;

  -- remember SportsCult so we can prove we did not touch it
  select do_not_contact, stage, phone_confidence into v_other
    from sales.leads where phone = '9502729320';

  -- the number, not the academy, is the problem. Scoped to ONE phone.
  delete from sales.dnc where phone = v_phone;

  update sales.leads
     set do_not_contact = false,
         -- they were never contacted, so 'lost' was never true either
         stage = 'new'
   where id = v_id;

  -- record WHY through the real function, so the phone_confidence downgrade
  -- and the stage rule come from one place rather than being reimplemented
  perform sales_log_touch(
    v_id, 'whatsapp', 'wrong_number', 'out', null, null, null,
    'Number has no WhatsApp account — one tick, never delivered. Was marked '
    || 'do-not-contact on 2026-08-12 because Stop was the only button that '
    || 'took a bad number out of the queue. They never refused us.',
    null, v_lead.variant);

  -- ── prove the end state ──
  select * into v_lead from sales.leads where id = v_id;
  if v_lead.do_not_contact then raise exception 'still suppressed'; end if;
  if v_lead.phone_confidence <> 'malformed' then
    raise exception 'phone_confidence is %, expected malformed', v_lead.phone_confidence;
  end if;
  if v_lead.stage <> 'new' then
    raise exception 'stage is %, expected new — wrong_number must not advance it',
      v_lead.stage;
  end if;

  -- it must NOT come back into the queue: malformed is not callable
  select count(*) into n from sales.leads
   where id = v_id and phone_confidence in ('verified', 'directory');
  if n <> 0 then raise exception 'CR Tennis is callable again — it would be re-messaged'; end if;

  -- and it must not count as a delivered send in either arm
  if (sales_ab_results()->'A'->>'sent')::int <> 1 then
    raise exception 'arm A delivered count is %, expected 1',
      sales_ab_results()->'A'->>'sent';
  end if;
  if (sales_ab_results()->'A'->>'undelivered')::int < 1 then
    raise exception 'the wrong number is not counted as undelivered';
  end if;

  -- blast radius: SportsCult must be untouched, and its dnc row must remain
  select count(*) into n from sales.dnc where phone = '9502729320';
  if n <> 1 then raise exception 'SportsCult dnc row was removed'; end if;
  select count(*) into n from sales.leads
   where phone = '9502729320' and do_not_contact
     and stage = v_other.stage and phone_confidence = v_other.phone_confidence;
  if n <> 1 then raise exception 'SportsCult was modified'; end if;

  select count(*) into n from sales.dnc;
  if n <> 1 then raise exception 'sales.dnc holds % rows, expected 1', n; end if;

  raise notice 'CR Tennis: wrong number, not a refusal. Out of the queue, '
    'out of the denominator, and no longer counted as an academy that said no.';
  raise notice 'STILL SUPPRESSED AS A REFUSAL WITH ZERO TOUCHES: SportsCult '
    'Sports Academy (9502729320) — needs the owner to say what happened.';
end $$;
