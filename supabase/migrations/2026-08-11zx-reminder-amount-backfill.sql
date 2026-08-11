-- ============================================================
-- 2026-08-11zx · Every reminder now says how much
-- scope: shared
--
-- reminder_events.amount was null on 527 of 581 rows, because the engine
-- only stamped it once a parent picked a plan — and most reminders never
-- get that far. So the tracking table could not answer the obvious
-- question next to a name: chased for how much.
--
-- The engine now resolves it at send time through genalpha.quote_fee(),
-- which is resolve_fee() and therefore the same number every other part
-- of the platform would quote. This backfills the rows that predate that.
--
-- Written as a migration after the fact: the UPDATE was run directly
-- while diagnosing, and a data change that large belongs in the ledger
-- even though ddl_log does not see DML. Re-running is a no-op — it only
-- touches rows where amount is still null.
-- ============================================================

update reminder_events r
   set amount = (resolve_fee('genalpha', d.member_id, e.centre_id, e.sport,
                             e.batch_id, e.plan_months, e.custom_amount)->>'amount')::numeric
  from genalpha.student_details d
  join enrollments e on e.member_id = d.member_id and e.tenant_id = 'genalpha'
 where r.tenant_id = 'genalpha'
   and r.member_id = d.member_id
   and r.amount is null;

do $$
declare n int; total int;
begin
  select count(*), count(amount) into total, n from reminder_events where tenant_id='genalpha';
  if n <> total then
    raise exception '% of % genalpha reminders still have no amount', total - n, total;
  end if;

  -- and the amounts must be per-student, not one number repeated: 52 of
  -- 81 players are not on the 3500 default.
  select count(distinct amount) into n from reminder_events where tenant_id='genalpha';
  if n < 5 then raise exception 'only % distinct amounts — the fee chain is not being read', n; end if;

  -- no other tenant was touched
  select count(*) into n from reminder_events where tenant_id <> 'genalpha' and amount is not null;
  raise notice 'genalpha: % reminders all carry an amount, % distinct values; other tenants untouched (% with amounts)',
    total, (select count(distinct amount) from reminder_events where tenant_id='genalpha'), n;
end $$;
