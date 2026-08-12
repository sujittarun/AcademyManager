-- Put Zero Blunder Chess Academy back in the queue.
--
-- WHY
--
-- It was logged as 'sent' at 15:04 IST on 2026-08-12 and advanced to
-- 'contacted', but nothing was actually sent — the click landed on a cached
-- console still running the pre-fix code, which recorded a send the moment
-- the chat opened rather than asking. The owner confirmed no message went
-- out.
--
-- Left alone it does two kinds of harm: the lead is skipped as
-- already-worked (it is the highest-scoring prospect on the list at 10/10),
-- and it sits in arm A's denominator, so the A/B reply rate reads low for a
-- send that never happened.
--
-- This is the same class of error as 2026-08-12zf/zg, arriving by a
-- different route: there the console logged a draft as a send, here a stale
-- copy of that console did. Cache-busters were bumped when the fix shipped,
-- but a tab already open keeps the old script.
--
-- NARROW ON PURPOSE
--
-- One lead, matched by name, and only if its touch history is exactly the
-- one phantom send. If anything else is there — a reply, a real second
-- touch — it stops, because then a human needs to look rather than have a
-- migration guess.
--
-- Scope: shared. One lead, one touch row.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

do $$
declare
  v_lead   uuid;
  v_stage  text;
  n_touch  int;
  n_odd    int;
begin
  select id, stage into v_lead, v_stage
    from sales.leads
   where name = 'Zero Blunder Chess Academy';

  if v_lead is null then
    raise exception 'Zero Blunder Chess Academy not found — has the lead been renamed?';
  end if;

  select count(*) into n_touch from sales.touches where lead_id = v_lead;

  -- anything other than a single outbound 'sent' means a human should look
  select count(*) into n_odd from sales.touches
   where lead_id = v_lead
     and not (direction = 'out' and outcome = 'sent');

  if n_odd > 0 then
    raise exception
      'refusing: % of % touch(es) on this lead are not a plain outbound send. '
      'It may have genuinely been worked — inspect before resetting.',
      n_odd, n_touch;
  end if;
  if n_touch > 1 then
    raise exception
      'refusing: % touches on this lead, expected the one phantom send',
      n_touch;
  end if;

  delete from sales.touches where lead_id = v_lead;

  update sales.leads
     set stage = 'new',
         last_touch_at = null,
         next_action_on = null
   where id = v_lead;

  raise notice 'Zero Blunder reset: was %, % touch(es) removed', v_stage, n_touch;
end $$;

-- Read-only assertions. 2026-08-12zf wrote from its own assertion block and
-- left two touches plus a wrongly-contacted lead in production; zg had to
-- clean up after it. Checks here observe and never write.
do $$
declare v_stage text; n int; r jsonb;
begin
  select stage into v_stage from sales.leads
   where name = 'Zero Blunder Chess Academy';
  if v_stage <> 'new' then
    raise exception 'Zero Blunder is still at %', v_stage;
  end if;

  select count(*) into n from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.name = 'Zero Blunder Chess Academy';
  if n <> 0 then
    raise exception '% touch(es) survive on Zero Blunder', n;
  end if;

  -- the A/B denominator must be back to zero on both arms
  r := sales_ab_results();
  if (r->'A'->>'sent')::int + (r->'B'->>'sent')::int <> 0 then
    raise exception 'the A/B test still counts % send(s)',
      (r->'A'->>'sent')::int + (r->'B'->>'sent')::int;
  end if;

  -- and the whole pipeline should be untouched again
  select count(*) into n from sales.leads
   where stage <> 'new' and not do_not_contact;
  if n > 0 then
    raise exception '% lead(s) are past new with nothing sent', n;
  end if;

  raise notice 'pipeline clean: every lead new, A/B at zero';
end $$;
