-- ============================================================
-- 2026-08-12i · Make reminder_events.status agree with its timestamps
-- scope: shared
--
-- The owner's question was "how do we know if a message reached the
-- parent" — the status column was not answering it, and for two
-- different reasons.
--
-- 1. THE LADDER RAN BACKWARDS. The webhook handler assigned `status`
--    from whatever Meta callback arrived last, and Meta does not
--    guarantee order. So `delivered` arriving after `read` demoted the
--    row. One row is sitting in exactly that state right now: status
--    'delivered' with read_at set.
--
--    Worse, the same assignment overwrote statuses that are NOT delivery
--    states at all — payment_link_sent, payment_attempted,
--    payment_confirmed, help_requested. 63 payment_confirmed rows carry
--    a delivered_at, so a single late callback would have erased the
--    record that a parent had paid. That is a money fact destroyed by a
--    delivery receipt.
--
--    Fixed in the function (advanceDeliveryStatus, forward-only, and it
--    refuses to touch a conversation status). This file repairs the rows
--    that already exist.
--
-- 2. NOTHING WAS BROKEN ABOUT delivered ITSELF. 76 rows already read
--    'delivered' and 230 read 'read' with delivered_at set — 'read'
--    correctly outranks it. What the owner saw was today's 10:45 batch
--    stuck at 'accepted', because those messages' sent/delivered
--    callbacks fired at ~10:59 UTC, inside the webhook repoint window,
--    and landed on the legacy project. Their read callbacks arrived
--    after the repoint, which is why some rows look read-but-never-
--    delivered. Those receipts are gone; this file infers what it can
--    from the timestamps that DID land and leaves the rest alone.
--
-- The timestamps were always written correctly. Only `status` lied, so
-- only `status` is touched here — no _at column is invented.
-- ============================================================

-- ------------------------------------------------------------
-- Repair, most-advanced rung wins, and never over a conversation status
-- ------------------------------------------------------------
-- NOTE ON WHICH RELATION. The two halves live apart: `status` is a
-- column on the shared public.reminder_events, while the delivery
-- timestamps are on genalpha.reminder_event_details, keyed by
-- reminder_event_id. genalpha.reminder_events is the view that joins
-- them and cannot be updated here. Stated explicitly because the wrong
-- reminder_events was edited more than once today.

-- Snapshot every other tenant first, so "nobody else moved" is proved
-- against real rows rather than asserted from reading the WHERE clauses.
create temp table other_tenants_before on commit drop as
  select id, status from public.reminder_events where tenant_id <> 'genalpha';

update public.reminder_events re
   set status = 'read'
  from genalpha.reminder_event_details x
 where x.reminder_event_id = re.id
   and re.tenant_id = 'genalpha'
   and x.read_at is not null
   and re.status in ('queued','accepted','sent','delivered','dry_run');

update public.reminder_events re
   set status = 'delivered'
  from genalpha.reminder_event_details x
 where x.reminder_event_id = re.id
   and re.tenant_id = 'genalpha'
   and x.delivered_at is not null
   and x.read_at is null
   and re.status in ('queued','accepted','sent','dry_run');

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n_backwards int; n_lost int; n_delivered int; n_read int; n_conv int; n_other int;
begin
  -- no row may claim a rung below a timestamp it carries
  select count(*) into n_backwards from genalpha.reminder_events
   where (read_at is not null and status in ('queued','accepted','sent','delivered','dry_run'))
      or (delivered_at is not null and read_at is null
          and status in ('queued','accepted','sent','dry_run'));
  if n_backwards > 0 then
    raise exception '% rows still sit below the rung their timestamps prove', n_backwards;
  end if;

  -- and no conversation status was trampled by the repair
  select count(*) into n_conv from genalpha.reminder_events
   where status in ('payment_confirmed','payment_link_sent','payment_attempted',
                    'payment_pending_verification','help_requested','manual_followup');
  if n_conv < 120 then
    raise exception 'only % conversation-status rows survive; the repair ate some (expected ~125)', n_conv;
  end if;

  -- a failed send must not have been promoted
  select count(*) into n_lost from genalpha.reminder_events
   where status in ('failed','send_failed') and (delivered_at is not null or read_at is not null);
  if n_lost > 0 then
    raise exception '% failed rows carry a delivery timestamp', n_lost;
  end if;

  select count(*) into n_delivered from genalpha.reminder_events where status = 'delivered';
  select count(*) into n_read      from genalpha.reminder_events where status = 'read';
  raise notice 'status now: % delivered, % read, % conversation rows',
    n_delivered, n_read, n_conv;

  -- nobody else moved, compared row by row against the snapshot
  select count(*) into n_other
    from other_tenants_before b
    join public.reminder_events re on re.id = b.id
   where re.status is distinct from b.status;
  if n_other > 0 then
    raise exception '% rows belonging to other tenants changed status', n_other;
  end if;
end $$;
