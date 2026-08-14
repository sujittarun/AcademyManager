-- Sales, rebuilt around the only question a salesperson asks: who do I talk
-- to today — and on what the ticks actually said.
--
-- WHAT THE EVIDENCE CHANGED
--
-- 39 openers delivered, 0 replies. The tick check settled why: almost all
-- show TWO GREY TICKS. Delivered, not opened. That rules out the two
-- explanations we would otherwise have kept guessing between:
--
--   · not the phone list — the messages arrived
--   · not the copy — nobody read far enough for wording to matter
--
-- A delivered, unopened message does not want a second message. It wants a
-- phone call, while it is still sitting unread at the top of their chat list.
-- So the cadence here is CALL-FIRST after the opener, and there are no
-- follow-up message templates at all. That is the owner's call too: "follow-up
-- messages are not required for now."
--
-- WHAT WAS WRONG WITH THE OLD MODEL
--
-- It was a send-logging machine wearing the costume of a sales tool. It asked
-- "did you send it?" after every message — double entry, since the work was
-- already done in WhatsApp — and the tax was paid per lead. Eight real sends
-- went unrecorded because the confirm step got skipped.
--
-- It also had no concept of a SECOND touch. 39 academies were messaged once
-- and then nothing, with `next_action_on` NULL on all 135 rows, so no query
-- the console made could ever surface them again. They were abandoned
-- silently. This migration surfaces them without a backfill: due-ness is
-- computed from touch history, so every already-contacted lead becomes a
-- call the day after it was messaged.
--
-- WHAT REPLACES IT
--
--   sales_today()        one ordered queue. Replies, then booked calls, then
--                        demo-openers who never replied, then snoozes due,
--                        then calls the cadence says are due, then fresh
--                        leads — rationed by a daily cap.
--   sales_disposition()  one write path. You say what happened; it sets the
--                        stage, the next action and its date together, so a
--                        lead can never again be "contacted" with no next step.
--   sales_funnel()       where leads die, including why they were lost.
--
-- THE CAP IS NOT ADVICE. 35 leads were messaged on 2026-08-14 IST against a
-- safe ceiling of ~25 for a young WhatsApp Business number. A restricted
-- sender does not slow a campaign down — it stops fee reminders for every
-- live academy at once, because outreach and reminders are different numbers
-- but the same platform reputation risk. So the queue rations new
-- conversations and says out loud what it is holding back.
--
-- Scope: shared (sales schema, operator-only). Additive: every existing
-- function keeps working, so the console cannot break before its UI is
-- replaced.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

-- ─────────────────────────────────────────────────────────────
-- 1. two columns the model needs
-- ─────────────────────────────────────────────────────────────
alter table sales.leads
  add column if not exists lost_reason      text,
  -- WHY a date is set. A chase the cadence scheduled and a date the prospect
  -- asked for are different facts, and the queue must never present
  -- "call me in March" as an overdue follow-up.
  add column if not exists next_action_kind text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'leads_next_action_kind_check') then
    alter table sales.leads add constraint leads_next_action_kind_check
      check (next_action_kind is null or next_action_kind in
             ('call', 'snooze', 'reply', 'meeting'));
  end if;
end $$;

comment on column sales.leads.next_action_kind is
  'Why next_action_on is set: call = the cadence scheduled it; snooze = the prospect asked for a later date; reply = they answered and are waiting on us; meeting = a call/demo is booked.';
comment on column sales.leads.lost_reason is
  'Only meaningful when stage = ''lost''. Answers "where do leads die?", which a stage count cannot.';

-- ─────────────────────────────────────────────────────────────
-- 2. the cadence — one place, so nothing can disagree
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_cadence(p_step int)
returns int language sql immutable as $$
  /* Days to wait AFTER touch p_step before the next is due.

     1 -> 1   the opener was delivered and not opened. Call TOMORROW, while
              it is still unread at the top of their chat list. Waiting three
              days throws away the only context the call has.
     2 -> 3   no answer. Try again, at a different time of day.
     3 -> 7   third and last attempt.
     4 -> 0   spent. Do not touch again without a new reason. */
  select case p_step when 1 then 1 when 2 then 3 when 3 then 7 else 0 end
$$;

create or replace function public.sales_cadence_channel(p_step int)
returns text language sql immutable as $$
  /* Touch 1 is the WhatsApp opener. Everything after it is a CALL — there
     are deliberately no follow-up message templates, because a message that
     was delivered and never opened does not get read on the second attempt
     either. */
  select case when coalesce(p_step, 1) <= 1 then 'whatsapp' else 'call' end
$$;

create or replace function public.sales_cadence_last_step()
returns int language sql immutable as $$ select 4 $$;

create or replace function public.sales_daily_cap()
returns int language sql immutable as $$
  /* marketing/leads/WHATSAPP-KIT.md §0: 20-30 new conversations a day on a
     young number. 25 is the middle. Exceeding it risks the sender, and a
     restricted sender is a platform-wide incident, not a marketing setback. */
  select 25
$$;

revoke execute on function public.sales_cadence(int),
                   public.sales_cadence_channel(int),
                   public.sales_cadence_last_step(),
                   public.sales_daily_cap() from public, anon;
grant  execute on function public.sales_cadence(int),
                   public.sales_cadence_channel(int),
                   public.sales_cadence_last_step(),
                   public.sales_daily_cap() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 3. sales_today() — the whole workflow in one call
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_today()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  v_today   date := (now() at time zone 'Asia/Kolkata')::date;
  v_started int;
  v_room    int;
  v_rows    jsonb;
  v_counts  jsonb;
  v_held    int;
  v_spent   int;
begin
  perform assert_operator();

  /* New conversations opened today, IST. Cadence CALLS do not count against
     the cap: phoning someone you already messaged is not cold outreach and
     carries no sender risk. Throttling it would punish the operator for
     doing the highest-value work on the list. */
  select count(*) into v_started from (
    select t.lead_id
      from sales.touches t
     where t.direction = 'out' and t.channel = 'whatsapp'
       and not sales_undelivered(t.outcome)
       and (t.occurred_at at time zone 'Asia/Kolkata')::date = v_today
     group by t.lead_id
    having min(t.occurred_at) = (
      select min(p.occurred_at) from sales.touches p
       where p.lead_id = t.lead_id and p.direction = 'out'
         and not sales_undelivered(p.outcome))
  ) q;

  v_room := greatest(sales_daily_cap() - v_started, 0);

  with base as (
    select l.id, l.name, l.contact_name, l.phone, l.alt_phones, l.sport,
           l.area, l.score, l.stage, l.variant, l.notes, l.owner,
           l.next_action_on, l.next_action_kind, l.students_est, l.branches,
           l.website_or_social, l.ref_code, l.phone_confidence,
           (select count(*) from sales.touches t
             where t.lead_id = l.id and t.direction = 'out'
               and not sales_undelivered(t.outcome))          as steps_done,
           (select count(*) from sales.touches t
             where t.lead_id = l.id and t.direction = 'in')   as inbound,
           (select max(t.occurred_at) from sales.touches t
             where t.lead_id = l.id and t.direction = 'out'
               and not sales_undelivered(t.outcome))          as last_out,
           (select count(*) from sales.demo_visits d
             where d.lead_id = l.id)                          as demo_hits
      from sales.leads l
     where not l.do_not_contact
       and l.stage not in ('won', 'lost')
       and l.phone is not null
       and l.phone_confidence in ('verified', 'directory')
  ),
  classified as (
    select b.*,
           b.steps_done + 1                          as next_step,
           -- count(*) is bigint; the cadence helpers take int
           sales_cadence_channel((b.steps_done + 1)::int) as next_channel,
           case
             when b.inbound > 0 or b.stage = 'replied'          then 'reply'
             when b.stage = 'call_booked'
              and coalesce(b.next_action_on, v_today) <= v_today then 'meeting'
             when b.demo_hits > 0 and b.inbound = 0             then 'demo'
             when b.next_action_kind = 'snooze'
              and b.next_action_on <= v_today                   then 'snoozed'
             when b.steps_done between 1 and sales_cadence_last_step() - 1
              and (b.last_out
                   + (sales_cadence(b.steps_done::int) || ' days')::interval) <= now()
                                                               then 'due'
             when b.steps_done = 0 and b.stage = 'new'          then 'new'
             else null
           end as bucket
      from base b
  ),
  labelled as (
    select c.*,
           case c.bucket
             when 'reply'   then 'they answered — you are the holdup'
             when 'meeting' then 'call you booked'
             when 'demo'    then 'opened the demo ' || c.demo_hits
                                  || 'x and never replied'
             when 'snoozed' then 'asked you to come back today'
             when 'due'     then 'messaged ' || (v_today - c.last_out::date)
                                  || 'd ago, delivered, no reply — call'
             when 'new'     then 'never contacted'
           end as reason,
           case c.bucket when 'reply' then 1 when 'meeting' then 2
                         when 'demo'  then 3 when 'snoozed' then 4
                         when 'due'   then 5 else 6 end as pri
      from classified c
     where c.bucket is not null
  ),
  ranked as (
    select l.*,
           case when l.bucket = 'new'
                then row_number() over (partition by l.bucket
                                        order by l.score desc, l.name)
                else 0 end as new_rank
      from labelled l
  )
  select jsonb_agg(to_jsonb(r) - 'new_rank' - 'pri'
                   order by r.pri, r.score desc, r.name),
         (select jsonb_object_agg(bucket, n)
            from (select bucket, count(*) n from ranked
                   where bucket <> 'new' or new_rank <= v_room
                   group by bucket) x),
         (select count(*) from ranked where bucket = 'new' and new_rank > v_room)
    into v_rows, v_counts, v_held
    from ranked r
   where r.bucket <> 'new' or r.new_rank <= v_room;

  /* Leads the cadence has finished with: not dead, just out of reasons. This
     is its own query because a CTE does not outlive the statement that
     declared it. */
  select count(*) into v_spent
    from sales.leads l
   where not l.do_not_contact
     and l.stage not in ('won', 'lost')
     and l.phone is not null
     and l.phone_confidence in ('verified', 'directory')
     and (select count(*) from sales.touches t
           where t.lead_id = l.id and t.direction = 'out'
             and not sales_undelivered(t.outcome)) >= sales_cadence_last_step()
     and not exists (select 1 from sales.touches t
                      where t.lead_id = l.id and t.direction = 'in');

  return jsonb_build_object(
    'today_ist', v_today,
    'started',   v_started,
    'cap',       sales_daily_cap(),
    'room',      v_room,
    'over_cap',  greatest(v_started - sales_daily_cap(), 0),
    'counts',    coalesce(v_counts, '{}'::jsonb),
    'rows',      coalesce(v_rows, '[]'::jsonb),
    'held_back', coalesce(v_held, 0),
    'spent',     coalesce(v_spent, 0));
end $$;

revoke execute on function public.sales_today() from public, anon;
grant  execute on function public.sales_today() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 4. sales_disposition() — one write path for "what happened"
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_disposition(
  p_lead     uuid,
  p_what     text,
  p_when     date default null,
  p_note     text default null,
  p_body     text default null,
  p_template text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  v_lead  sales.leads;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_steps int;
  v_stage text;
  v_kind  text;
  v_next  date;
  v_gap   int;
begin
  perform assert_operator();

  select * into v_lead from sales.leads where id = p_lead;
  if not found then raise exception 'no such lead %', p_lead; end if;

  v_stage := v_lead.stage;

  if p_what = 'messaged' then
    /* SENT, not "a draft was opened". The operator clicks this because they
       are sending; asking them to confirm afterwards is the double entry that
       lost eight real sends. `undo` is the exception path. */
    perform sales_log_touch(p_lead, 'whatsapp', 'sent', 'out', p_template,
                            p_body, null, p_note, null, v_lead.variant);
    if v_stage = 'new' then v_stage := 'contacted'; end if;

  elsif p_what = 'spoke' then
    -- got through and talked. The most valuable outcome on the board.
    perform sales_log_touch(p_lead, 'call', 'replied', 'out', null, null,
                            null, p_note, null, v_lead.variant);
    v_stage := 'replied';
    v_next  := v_today;
    v_kind  := 'reply';

  elsif p_what = 'no_answer' then
    perform sales_log_touch(p_lead, 'call', 'no_answer', 'out', null, null,
                            null, p_note, null, v_lead.variant);

  elsif p_what = 'gatekeeper' then
    /* Reached the front desk / a coach, not the decision maker. Very common
       when the published number is a facility line. It IS an attempt, so it
       advances the cadence, but the note carries who to ask for next time. */
    perform sales_log_touch(p_lead, 'call', 'no_answer', 'out', null, null,
                            null, coalesce(p_note, 'reached gatekeeper'),
                            null, v_lead.variant);

  elsif p_what = 'replied' then
    perform sales_log_touch(p_lead, 'whatsapp', 'replied', 'in', null, p_body,
                            null, p_note, null, v_lead.variant);
    v_stage := 'replied';
    v_next  := v_today;
    v_kind  := 'reply';

  elsif p_what = 'later' then
    -- the most common real outcome, and there was nowhere to put it
    if p_when is null then
      raise exception '"later" needs a date — that is the whole point of it';
    end if;
    if p_when <= v_today then
      raise exception 'a snooze to % is not later than today (%)', p_when, v_today;
    end if;
    update sales.leads set next_action_on = p_when, next_action_kind = 'snooze'
     where id = p_lead;
    return jsonb_build_object('lead', p_lead, 'what', p_what, 'stage', v_stage,
                              'next_action_on', p_when,
                              'next_action_kind', 'snooze');

  elsif p_what = 'booked' then
    if p_when is null then raise exception 'a booked call needs a date'; end if;
    v_stage := 'call_booked';
    v_next  := p_when;
    v_kind  := 'meeting';

  elsif p_what = 'not_interested' then
    perform sales_log_touch(p_lead, 'call', 'not_interested', 'in', null, null,
                            null, p_note, null, v_lead.variant);
    v_stage := 'lost';
    update sales.leads set lost_reason = coalesce(nullif(p_note, ''),
                                                  'not interested')
     where id = p_lead;

  elsif p_what = 'no_whatsapp' then
    -- the number is dead, the academy is not. Keep the lead, drop the number.
    perform sales_log_touch(p_lead, 'whatsapp', 'wrong_number', 'out', null,
                            null, null, p_note, null, v_lead.variant);

  elsif p_what = 'stop' then
    perform sales_set_dnc(p_lead, coalesce(nullif(p_note, ''),
                                           'asked us to stop'));
    return jsonb_build_object('lead', p_lead, 'what', p_what, 'stage', 'lost',
                              'next_action_on', null);

  elsif p_what = 'undo' then
    /* They opened the chat and did not send. Removes the most recent OUTBOUND
       touch only, and walks the stage back if it was the only one. */
    delete from sales.touches
     where id = (select t.id from sales.touches t
                  where t.lead_id = p_lead and t.direction = 'out'
                  order by t.occurred_at desc limit 1);
    select count(*) into v_steps from sales.touches t
     where t.lead_id = p_lead and t.direction = 'out'
       and not sales_undelivered(t.outcome);
    if v_steps = 0 then v_stage := 'new'; end if;
    update sales.leads
       set stage = v_stage, next_action_on = null, next_action_kind = null
     where id = p_lead;
    return jsonb_build_object('lead', p_lead, 'what', p_what, 'stage', v_stage,
                              'step', v_steps, 'next_action_on', null);

  else
    raise exception 'unknown disposition %', p_what;
  end if;

  /* Everything that advanced the cadence schedules its own next touch, so a
     lead can never end up "contacted" with no next step again. */
  select count(*) into v_steps from sales.touches t
   where t.lead_id = p_lead and t.direction = 'out'
     and not sales_undelivered(t.outcome);

  if v_next is null then
    v_gap := sales_cadence(v_steps);
    if v_gap > 0 and v_steps between 1 and sales_cadence_last_step() - 1 then
      v_next := v_today + v_gap;
      v_kind := 'call';
    end if;
  end if;

  update sales.leads
     set stage = v_stage, next_action_on = v_next, next_action_kind = v_kind
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'what', p_what, 'stage', v_stage,
                            'step', v_steps, 'next_action_on', v_next,
                            'next_action_kind', v_kind,
                            'next_channel', sales_cadence_channel(v_steps + 1));
end $$;

revoke execute on function public.sales_disposition(
  uuid,text,date,text,text,text) from public, anon;
grant  execute on function public.sales_disposition(
  uuid,text,date,text,text,text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 5. the funnel — where do leads die?
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_funnel()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare r jsonb;
begin
  perform assert_operator();
  select jsonb_build_object(
    'total',       count(*),
    'reachable',   count(*) filter (where not do_not_contact
                       and phone_confidence in ('verified','directory')),
    'contacted',   count(*) filter (where stage <> 'new'),
    'engaged',     count(*) filter (where stage in ('replied','call_booked',
                                                    'demo_done','won')),
    'booked',      count(*) filter (where stage in ('call_booked','demo_done','won')),
    'won',         count(*) filter (where stage = 'won'),
    'lost',        count(*) filter (where stage = 'lost'),
    'dead_number', count(*) filter (where phone_confidence = 'malformed'),
    'suppressed',  count(*) filter (where do_not_contact),
    'why_lost',    (select coalesce(jsonb_object_agg(q.reason, q.n), '{}'::jsonb)
                      from (select coalesce(nullif(lost_reason,''),
                                            'unspecified') as reason,
                                   count(*) as n
                              from sales.leads where stage = 'lost'
                             group by 1 order by 2 desc limit 8) q)
  ) into r from sales.leads;
  return r;
end $$;

revoke execute on function public.sales_funnel() from public, anon;
grant  execute on function public.sales_funnel() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- prove it, against real rows
-- ─────────────────────────────────────────────────────────────
do $$
declare
  n int; t jsonb; d jsonb; v_lead uuid; v_stage text;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then raise exception 'anon can execute % sales function(s)', n; end if;

  -- the cadence must be call-first: no follow-up MESSAGE exists
  if sales_cadence_channel(1) <> 'whatsapp' then
    raise exception 'touch 1 is not whatsapp'; end if;
  if sales_cadence_channel(2) <> 'call' or sales_cadence_channel(4) <> 'call' then
    raise exception 'a follow-up message survived: touch 2/4 is not a call'; end if;
  if sales_cadence(1) <> 1 then
    raise exception 'the first call is not next-day (got %)', sales_cadence(1); end if;

  t := sales_today();

  if (t->>'cap')::int <> 25 then raise exception 'cap is %', t->>'cap'; end if;

  -- 35 whatsapp openers went out today, so the cap must be exhausted and the
  -- queue must SAY what it is holding back rather than quietly showing a
  -- short list
  if (t->>'started')::int < 30 then
    raise exception 'only % conversations counted as started today', t->>'started';
  end if;
  if (t->>'room')::int <> 0 then
    raise exception 'cap not enforced: room = % after % starts',
      t->>'room', t->>'started';
  end if;
  if (t->>'held_back')::int < 1 then
    raise exception 'the cap is holding nothing back, yet % leads are fresh',
      (select count(*) from sales.leads where stage = 'new');
  end if;
  if coalesce((t->'counts'->>'new')::int, 0) <> 0 then
    raise exception 'new leads offered despite the cap being spent'; end if;

  /* ── the assertions below WRITE, so they roll themselves back ──
     A plpgsql block with an exception handler is a subtransaction, so raising
     a sentinel at the end of it undoes everything it did while still letting a
     genuine failure through (different message -> re-raised).

     This is not hypothetical tidiness. Migration 2026-08-12zf committed its
     own assertion side-effects and needed zg to clean up after it, and one of
     the assertions here marks a REAL prospect 'lost' with the reason "uses a
     rival app". A dry run would hide that: the runner rolls back, so the
     damage only appears on the real apply. */
  select l.id into v_lead
    from sales.leads l join sales.touches tt on tt.lead_id = l.id
   where l.stage = 'contacted' and not l.do_not_contact
     and tt.direction = 'out' and not sales_undelivered(tt.outcome)
   group by l.id having max(tt.occurred_at) is not null
   order by max(tt.occurred_at) desc limit 1;
  if v_lead is null then raise exception 'no contacted lead to test against'; end if;

  begin
    -- a lead messaged today must be scheduled for a CALL, not a message
    d := sales_disposition(v_lead, 'no_answer', null, 'assertion: rang, no pickup');
    if d->>'next_action_kind' <> 'call' then
      raise exception 'after a call attempt the next action is %, expected call',
        d->>'next_action_kind';
    end if;
    if (d->>'next_action_on')::date <> v_today + sales_cadence(2) then
      raise exception 'next call scheduled %, expected %',
        d->>'next_action_on', v_today + sales_cadence(2);
    end if;

    -- "later" must demand a real future date, or it is not a snooze
    begin
      d := sales_disposition(v_lead, 'later', v_today);
      raise exception 'a snooze to today was accepted';
    exception when others then
      if sqlerrm not like '%is not later than today%' then raise; end if;
    end;

    d := sales_disposition(v_lead, 'later', v_today + 30);
    if d->>'next_action_kind' <> 'snooze' then
      raise exception 'snooze kind is %', d->>'next_action_kind'; end if;

    -- losing a lead must record WHY, or the funnel cannot answer the question
    d := sales_disposition(v_lead, 'not_interested', null, 'uses a rival app');
    select stage into v_stage from sales.leads where id = v_lead;
    if v_stage <> 'lost' then raise exception 'stage is %', v_stage; end if;
    if (sales_funnel()->'why_lost'->>'uses a rival app') is null then
      raise exception 'the funnel does not report why that lead was lost'; end if;

    raise exception 'ASSERTIONS_PASSED_ROLLING_BACK';
  exception when others then
    if sqlerrm <> 'ASSERTIONS_PASSED_ROLLING_BACK' then raise; end if;
  end;

  -- and prove the rollback worked: the lead must be untouched
  select stage into v_stage from sales.leads where id = v_lead;
  if v_stage <> 'contacted' then
    raise exception 'the write assertions leaked: lead is now %, expected contacted',
      v_stage;
  end if;
  if exists (select 1 from sales.touches
              where lead_id = v_lead and notes like 'assertion:%') then
    raise exception 'an assertion touch was committed';
  end if;
  if (select count(*) from sales.leads where lost_reason = 'uses a rival app') > 0 then
    raise exception 'a real prospect was left marked lost by an assertion';
  end if;

  raise notice 'today: % due now, % started vs cap %, % new held back, % spent',
    jsonb_array_length(t->'rows'), t->>'started', t->>'cap',
    t->>'held_back', t->>'spent';
end $$;
