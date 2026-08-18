-- Sales, redesigned around the only question a salesperson actually asks:
-- "who do I talk to today?"
--
-- WHAT WAS WRONG WITH THE OLD MODEL
--
-- The Sales tab was a send-logging machine wearing the costume of a sales
-- tool. It asked "did you send it?" after every message, which is double
-- entry — the operator had already done the work in WhatsApp — and the tax
-- was paid on every single lead. Eight real sends went unrecorded because
-- the confirm step was skipped, and the queue jammed on the same names.
--
-- Worse, it had no concept of a SECOND touch. 39 academies were messaged
-- once and then nothing, forever, with `sales.leads.next_action_on` sitting
-- unused on every row. Most replies in cold outreach come from touch 2 to 4.
-- A tool that only supports touch 1 discards most of its own pipeline.
--
-- WHAT REPLACES IT
--
-- 1. A CADENCE, in the database. Day 0 opener, +3 a demo link, +7 a
--    different angle, +14 a release, then spent. This mirrors
--    reminder_queue()'s ladder for exactly the same reason: the console, a
--    manual query and any future client must not disagree about who is due.
--
-- 2. sales_today() — ONE queue, ordered by what a human should care about
--    first. Replies before intent, intent before routine follow-up, routine
--    follow-up before fresh leads.
--
-- 3. The demo-intent bucket, which is the part a generic sales tool cannot
--    do. We built the demo and we track opens per lead, so a prospect who
--    clicked the link twice and never replied is the hottest row in the
--    pipeline. That is a buying signal nobody had to say out loud.
--
-- 4. A DAILY CAP on new conversations. WhatsApp restricts numbers that
--    blast, and a restricted sender stops fee reminders for every live
--    academy at once. The cap belongs in the queue, not in willpower.
--
-- 5. sales_disposition() — one write path. You say what happened; it sets
--    the stage, the next action and its date together, so a lead can never
--    end up "contacted" with no next step, which is how 39 of them were
--    silently abandoned.
--
-- Scope: shared (sales schema, operator-only). Additive — the existing
-- console keeps working until its UI is replaced.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

-- ─────────────────────────────────────────────────────────────
-- 1. two columns the model needs
-- ─────────────────────────────────────────────────────────────
alter table sales.leads
  add column if not exists lost_reason      text,
  -- WHY a date was set. A follow-up the cadence scheduled and a date the
  -- prospect asked for are different facts, and the queue must not present
  -- "call me in March" as an overdue chase.
  add column if not exists next_action_kind text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'leads_next_action_kind_check') then
    alter table sales.leads add constraint leads_next_action_kind_check
      check (next_action_kind is null or next_action_kind in
             ('followup', 'snooze', 'reply', 'call'));
  end if;
end $$;

comment on column sales.leads.next_action_kind is
  'Why next_action_on is set: followup = the cadence scheduled it; snooze = the prospect asked for a later date; reply = they answered and are waiting on us; call = a call is booked.';
comment on column sales.leads.lost_reason is
  'Free text, only meaningful when stage = ''lost''. Answers "where do leads die?", which a stage count alone cannot.';

-- ─────────────────────────────────────────────────────────────
-- 2. the cadence — one place, so nothing can disagree
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_cadence(p_step int)
returns int language sql immutable as $$
  /* Days to wait AFTER touch p_step before the next one is due. Shaped like
     reminder_queue()'s ladder: close at first, then widen, then stop —
     because a chase that keeps arriving forever earns a block, not a reply.

       1 -> 3   the opener got no answer; a short nudge still reads as human
       2 -> 4   (day 7) a different angle, not a repeat
       3 -> 7   (day 14) the release. Saying "I'll stop here" earns replies
       4 -> 0   spent. Never message again without a new reason. */
  select case p_step when 1 then 3 when 2 then 4 when 3 then 7 else 0 end
$$;

create or replace function public.sales_cadence_last_step()
returns int language sql immutable as $$ select 4 $$;

-- how many new conversations may still start today, in IST
create or replace function public.sales_daily_cap()
returns int language sql immutable as $$
  /* The WhatsApp Business App guidance in marketing/leads/WHATSAPP-KIT.md is
     20-30 new conversations a day on a young number. 25 is the middle, and
     the cost of exceeding it is not a slower campaign — it is a restricted
     sender, which stops fee reminders for every live academy at once. */
  select 25
$$;

revoke execute on function public.sales_cadence(int) from public, anon;
revoke execute on function public.sales_cadence_last_step() from public, anon;
revoke execute on function public.sales_daily_cap() from public, anon;
grant execute on function public.sales_cadence(int),
                 public.sales_cadence_last_step(),
                 public.sales_daily_cap() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 3. sales_today() — the whole workflow, in one call
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
begin
  perform assert_operator();

  /* New conversations already started today, IST. The cadence's own
     follow-ups do NOT count against the cap: replying to someone you are
     already talking to is not cold outreach, and throttling it would punish
     the operator for doing the highest-value work on the list. */
  select count(distinct t.lead_id) into v_started
    from sales.touches t
   where t.direction = 'out'
     and not sales_undelivered(t.outcome)
     and (t.occurred_at at time zone 'Asia/Kolkata')::date = v_today
     and not exists (select 1 from sales.touches p
                      where p.lead_id = t.lead_id and p.direction = 'out'
                        and not sales_undelivered(p.outcome)
                        and p.occurred_at < t.occurred_at);

  v_room := greatest(sales_daily_cap() - v_started, 0);

  with base as (
    select l.*,
           -- delivered outbound touches = which cadence step they are on
           (select count(*) from sales.touches t
             where t.lead_id = l.id and t.direction = 'out'
               and not sales_undelivered(t.outcome))            as steps_done,
           (select count(*) from sales.touches t
             where t.lead_id = l.id and t.direction = 'in')     as inbound,
           (select max(t.occurred_at) from sales.touches t
             where t.lead_id = l.id and t.direction = 'out'
               and not sales_undelivered(t.outcome))            as last_out,
           (select count(*) from sales.demo_visits d
             where d.lead_id = l.id)                            as demo_hits,
           (select max(d.at) from sales.demo_visits d
             where d.lead_id = l.id)                            as demo_last
      from sales.leads l
     where not l.do_not_contact
       and l.stage not in ('won', 'lost')
       and l.phone is not null
       and l.phone_confidence in ('verified', 'directory')
  ),
  classified as (
    select b.*,
           b.steps_done + 1 as next_step,
           case
             -- 1. they answered. Nothing on this list matters more.
             when b.inbound > 0 or b.stage = 'replied'      then 'reply'
             -- 2. a call they asked for
             when b.stage = 'call_booked'
              and coalesce(b.next_action_on, v_today) <= v_today then 'call'
             -- 3. they opened the demo and said nothing. Intent without words.
             when b.demo_hits > 0 and b.inbound = 0         then 'demo'
             -- 4. a date the prospect themselves asked for
             when b.next_action_kind = 'snooze'
              and b.next_action_on <= v_today               then 'snoozed'
             -- 5. routine follow-up: the cadence says it is time
             when b.steps_done between 1 and sales_cadence_last_step() - 1
              and (b.last_out + (sales_cadence(b.steps_done) || ' days')::interval)
                   <= now()                                 then 'followup'
             -- 6. never contacted
             when b.steps_done = 0 and b.stage = 'new'      then 'new'
             else null
           end as bucket
      from base b
  ),
  ranked as (
    select c.*,
           case c.bucket when 'reply' then 1 when 'call' then 2
                         when 'demo'  then 3 when 'snoozed' then 4
                         when 'followup' then 5 else 6 end as pri,
           -- fresh leads are rationed; everything else is genuinely due
           case when c.bucket = 'new'
                then row_number() over (partition by c.bucket
                                        order by c.score desc, c.name)
                else 0 end as new_rank
      from classified c
     where c.bucket is not null
  )
  select jsonb_agg(to_jsonb(r) - 'new_rank' - 'pri' order by r.pri,
                   r.score desc, r.name)
    into v_rows
    from ranked r
   where r.bucket <> 'new' or r.new_rank <= v_room;

  select jsonb_object_agg(bucket, n) into v_counts
    from (select bucket, count(*) as n from ranked
           where bucket <> 'new' or new_rank <= v_room group by bucket) q;

  return jsonb_build_object(
    'today_ist',   v_today,
    'started',     v_started,
    'cap',         sales_daily_cap(),
    'room',        v_room,
    'counts',      coalesce(v_counts, '{}'::jsonb),
    'rows',        coalesce(v_rows, '[]'::jsonb),
    -- leads the cadence has finished with: not dead, just out of reasons
    'spent',       (select count(*) from base
                     where steps_done >= sales_cadence_last_step()
                       and inbound = 0),
    -- and what the cap is holding back, so a short day is never a mystery
    'held_back',   (select count(*) from ranked
                     where bucket = 'new' and new_rank > v_room));
end $$;

revoke execute on function public.sales_today() from public, anon;
grant  execute on function public.sales_today() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 4. sales_disposition() — one write path for "what happened"
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_disposition(
  p_lead    uuid,
  p_what    text,
  p_when    date default null,
  p_note    text default null,
  p_channel text default 'whatsapp',
  p_body    text default null,
  p_template text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  v_lead   sales.leads;
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_steps  int;
  v_stage  text;
  v_kind   text;
  v_next   date;
  v_gap    int;
begin
  perform assert_operator();

  select * into v_lead from sales.leads where id = p_lead;
  if not found then raise exception 'no such lead %', p_lead; end if;

  select count(*) into v_steps from sales.touches t
   where t.lead_id = p_lead and t.direction = 'out'
     and not sales_undelivered(t.outcome);

  v_stage := v_lead.stage;
  v_kind  := null;
  v_next  := null;

  if p_what = 'messaged' then
    /* The message was SENT. Not "a draft was opened" — the operator clicks
       this because they are sending, and asking them to confirm afterwards
       is the double entry that lost eight real sends. `undo` is the
       exception path. */
    perform sales_log_touch(p_lead, p_channel, 'sent', 'out', p_template,
                            p_body, null, p_note, null, v_lead.variant);
    v_steps := v_steps + 1;
    v_gap   := sales_cadence(v_steps);
    if v_stage = 'new' then v_stage := 'contacted'; end if;
    if v_gap > 0 then
      v_next := v_today + v_gap;
      v_kind := 'followup';
    end if;                       -- past the last step: spent, no next date

  elsif p_what = 'replied' then
    perform sales_log_touch(p_lead, p_channel, 'replied', 'in', null,
                            p_body, null, p_note, null, v_lead.variant);
    v_stage := 'replied';
    v_next  := v_today;           -- they are waiting on us, today
    v_kind  := 'reply';

  elsif p_what = 'later' then
    -- the most common real outcome, and there was nowhere to put it
    if p_when is null then
      raise exception '"later" needs a date — that is the whole point of it';
    end if;
    if p_when <= v_today then
      raise exception 'a snooze to % is not later than today (%)', p_when, v_today;
    end if;
    v_next := p_when;
    v_kind := 'snooze';

  elsif p_what = 'call_booked' then
    if p_when is null then raise exception 'a booked call needs a date'; end if;
    v_stage := 'call_booked';
    v_next  := p_when;
    v_kind  := 'call';

  elsif p_what = 'not_interested' then
    perform sales_log_touch(p_lead, p_channel, 'not_interested', 'in', null,
                            null, null, p_note, null, v_lead.variant);
    v_stage := 'lost';
    update sales.leads set lost_reason = coalesce(p_note, 'not interested')
     where id = p_lead;

  elsif p_what = 'no_whatsapp' then
    -- the number is dead, the academy is not. Keep the lead, drop the number.
    perform sales_log_touch(p_lead, p_channel, 'wrong_number', 'out', null,
                            null, null, p_note, null, v_lead.variant);

  elsif p_what = 'stop' then
    -- a genuine refusal. Permanent, and it must survive a re-import.
    perform sales_set_dnc(p_lead, coalesce(p_note, 'asked us to stop'));
    return jsonb_build_object('lead', p_lead, 'what', p_what,
                              'stage', 'lost', 'next_action_on', null);

  elsif p_what = 'undo' then
    /* The exception to "messaged means sent": they opened the chat and did
       not send. Removes the most recent OUTBOUND touch only, and walks the
       stage back if that was the only one. */
    delete from sales.touches
     where id = (select t.id from sales.touches t
                  where t.lead_id = p_lead and t.direction = 'out'
                  order by t.occurred_at desc limit 1);
    select count(*) into v_steps from sales.touches t
     where t.lead_id = p_lead and t.direction = 'out'
       and not sales_undelivered(t.outcome);
    if v_steps = 0 then v_stage := 'new'; else v_stage := v_lead.stage; end if;

  else
    raise exception 'unknown disposition %', p_what;
  end if;

  update sales.leads
     set stage            = v_stage,
         next_action_on   = v_next,
         next_action_kind = v_kind
   where id = p_lead;

  return jsonb_build_object('lead', p_lead, 'what', p_what, 'stage', v_stage,
                            'step', v_steps, 'next_action_on', v_next,
                            'next_action_kind', v_kind);
end $$;

revoke execute on function public.sales_disposition(
  uuid,text,date,text,text,text,text) from public, anon;
grant  execute on function public.sales_disposition(
  uuid,text,date,text,text,text,text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- 5. the funnel, with conversion — "where do leads die?"
-- ─────────────────────────────────────────────────────────────
create or replace function public.sales_funnel()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare r jsonb;
begin
  perform assert_operator();
  select jsonb_build_object(
    'reachable', count(*) filter (where not do_not_contact
                     and phone_confidence in ('verified','directory')),
    'contacted', count(*) filter (where stage <> 'new'),
    'replied',   count(*) filter (where stage in ('replied','call_booked','demo_done','won')),
    'call',      count(*) filter (where stage in ('call_booked','demo_done','won')),
    'won',       count(*) filter (where stage = 'won'),
    'lost',      count(*) filter (where stage = 'lost'),
    'dead_number', count(*) filter (where phone_confidence = 'malformed'),
    'suppressed', count(*) filter (where do_not_contact),
    'why_lost',  (select coalesce(jsonb_object_agg(r2.reason, r2.n), '{}'::jsonb)
                    from (select coalesce(lost_reason,'unspecified') as reason,
                                 count(*) as n
                            from sales.leads where stage = 'lost'
                           group by 1 order by 2 desc limit 8) r2)
  ) into r from sales.leads;
  return r;
end $$;

revoke execute on function public.sales_funnel() from public, anon;
grant  execute on function public.sales_funnel() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- prove it
-- ─────────────────────────────────────────────────────────────
do $$
declare n int; t jsonb; d jsonb; v_lead uuid;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then raise exception 'anon can execute % sales function(s)', n; end if;

  t := sales_today();

  -- the 39 already-contacted leads must now appear as follow-ups. Before this
  -- migration they were unreachable by any query the console made.
  if coalesce((t->'counts'->>'followup')::int, 0) < 30 then
    raise exception 'only % follow-ups surfaced; expected the ~39 contacted leads',
      coalesce(t->'counts'->>'followup', '0');
  end if;

  -- the cap must actually ration new leads
  if (t->>'cap')::int <> 25 then raise exception 'cap is %', t->>'cap'; end if;
  if jsonb_array_length(t->'rows') = 0 then raise exception 'today is empty'; end if;

  -- a snooze must refuse a date that is not in the future, or "later" is a lie
  select id into v_lead from sales.leads
   where stage = 'contacted' and not do_not_contact limit 1;
  begin
    d := sales_disposition(v_lead, 'later', (now() at time zone 'Asia/Kolkata')::date);
    raise exception 'a snooze to today was accepted';
  exception when others then
    if sqlerrm like '%is not later than today%' then null; else raise; end if;
  end;

  -- and "later" must record WHY the date is set, or the queue will present a
  -- prospect's own request as an overdue chase
  d := sales_disposition(v_lead, 'later',
                         (now() at time zone 'Asia/Kolkata')::date + 30);
  if d->>'next_action_kind' <> 'snooze' then
    raise exception 'snooze kind is %', d->>'next_action_kind';
  end if;

  raise notice 'today: % rows, % follow-ups overdue, % new held back by the cap',
    jsonb_array_length(t->'rows'), t->'counts'->>'followup', t->>'held_back';
end $$;
