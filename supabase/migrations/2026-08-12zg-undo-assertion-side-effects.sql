-- Remove touches written by 2026-08-12zf's own assertion block.
--
-- WHAT HAPPENED
--
-- 2026-08-12zf proved that a draft ('opened') does not advance a lead's stage
-- while a real 'sent' does. It proved it by calling sales_log_touch() twice
-- against a REAL lead — the first row returned by `order by id limit 1`.
--
-- Inside `--dry-run` and run-test.sh that is harmless, because both roll the
-- transaction back. Applied for real it is not: the two touches persisted and
-- that lead is now sitting at 'contacted' having never been messaged. Which
-- is precisely the bug zf was written to fix, reintroduced by the test for it.
--
-- THE LESSON, worth more than the two rows
--
-- An in-migration assertion that WRITES must undo what it wrote, or be
-- confined to a transaction that is thrown away. Every earlier migration in
-- this series asserted by reading the catalogue or counting rows, which is
-- why none of them left a mark. zf reached for sales_log_touch() because it
-- was the only way to observe the stage machine, and that is a fair thing to
-- want — but it should have captured the lead's prior stage and restored it,
-- or asserted against a lead it created and then deleted.
--
-- zf cannot be edited: schema_migrations is keyed on filename + sha256, so
-- changing it now would make the ledger refuse it. Hence a follow-up.
--
-- Scope: shared. Removes two rows and returns one lead to the queue.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

do $$
declare n_touch int; n_real int; v_leads uuid[];
begin
  -- Refuse to run if anything here looks like real outreach. The owner has
  -- sent nothing yet, so every touch should be an artifact: no template, no
  -- body, no sent_from. If that is not true, stop rather than destroy a
  -- genuine record.
  select count(*) into n_touch from sales.touches;
  select count(*) into n_real  from sales.touches
   where template is not null or body is not null or sent_from is not null
      or direction = 'in' or outcome in ('replied', 'not_interested');
  if n_real > 0 then
    raise exception
      'refusing: % of % touch(es) look like real outreach, not assertion '
      'artifacts. Clean them by hand.', n_real, n_touch;
  end if;

  select array_agg(distinct lead_id) into v_leads from sales.touches;

  delete from sales.touches;

  update sales.leads
     set stage = 'new', last_touch_at = null
   where id = any(coalesce(v_leads, '{}'::uuid[]))
     and stage = 'contacted'
     and not do_not_contact;

  raise notice 'removed % assertion artifact(s); % lead(s) returned to new',
    n_touch, coalesce(array_length(v_leads, 1), 0);
end $$;

-- Read-only assertions. This migration writes, so its checks must not.
do $$
declare n int;
begin
  select count(*) into n from sales.touches;
  if n <> 0 then
    raise exception '% touch(es) remain', n;
  end if;

  select count(*) into n from sales.leads
   where stage <> 'new' and not do_not_contact;
  if n > 0 then
    raise exception '% lead(s) are past new with no touches at all', n;
  end if;

  select count(*) into n from sales.leads where last_touch_at is not null;
  if n > 0 then
    raise exception '% lead(s) still carry a last_touch_at', n;
  end if;

  -- and the A/B test must be back to a clean slate
  if (sales_ab_results()->'A'->>'sent')::int
   + (sales_ab_results()->'B'->>'sent')::int <> 0 then
    raise exception 'the A/B test still counts sends';
  end if;

  raise notice 'pipeline is clean: 0 touches, every lead new, A/B at zero';
end $$;
