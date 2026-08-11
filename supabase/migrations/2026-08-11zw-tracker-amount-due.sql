-- ============================================================
-- 2026-08-11zw · What the family actually owes, on the tracker
-- scope: shared
--
-- reminder_events.amount is null on 527 of 581 rows. That is not a
-- regression — GenAlpha's own database was the same, because the engine
-- only stamps an amount once a parent picks a plan, and most reminders
-- never get that far.
--
-- It leaves the morning view unable to answer the obvious question next
-- to a name: how much. The platform does know — resolve_fee() is the
-- whole point of the fee chain — so the tracker resolves it per player
-- and falls back to the stamped amount when there is one.
--
-- amount_due is what to read; amount stays as the engine wrote it, so
-- nothing that reasons about "did the parent choose a plan" changes.
-- ============================================================

-- CREATE OR REPLACE cannot insert a column mid-list, only append. Drop and
-- rebuild: nothing depends on this view but a person reading it.
drop view if exists genalpha.reminder_tracker;
create view genalpha.reminder_tracker
with (security_invoker = true) as
  select (r.created_at at time zone 'Asia/Kolkata')::date as on_date,
         to_char(r.created_at at time zone 'Asia/Kolkata', 'HH24:MI') as at_ist,
         r.student_name,
         r.reg_no,
         r.reminder_type                           as rung,
         -- what the engine stamped (only once a plan is chosen) …
         r.amount,
         -- … and what the fee chain says they owe, which is always known
         coalesce(r.amount,
                  (resolve_fee('genalpha', d.member_id, e.centre_id, e.sport,
                               e.batch_id, e.plan_months, e.custom_amount)->>'amount')::numeric
         )                                          as amount_due,
         e.renewal_on                               as paid_through,
         r.due_date,
         r.overdue_days,
         r.status,

         case
           when r.payment_confirmed_at is not null            then '7 paid · confirmed'
           when r.payment_pending_verification_at is not null then '6 proof received'
           when r.payment_attempted_at is not null            then '5 tapped Pay Now'
           when r.payment_link_sent_at is not null            then '4 link sent'
           when coalesce(r.selected_plan,'') <> ''            then '3 plan chosen'
           when r.read_at is not null                         then '2 read'
           when r.delivered_at is not null                    then '1 delivered'
           when r.accepted_at is not null                     then '0 sent'
           when r.failed_at is not null                       then 'x failed'
           else '- queued'
         end                                        as journey,

         r.selected_plan,
         (r.upi_app_opened_at is not null)          as opened_upi_app,
         r.upi_seconds_away,
         r.parent_proof_nudge_status                as proof_nudge,

         r.delivered_at, r.read_at,
         r.payment_link_sent_at, r.payment_attempted_at,
         r.payment_pending_verification_at, r.payment_confirmed_at,
         r.failed_at,
         nullif(r.meta_error->>'message', '')       as failure_reason,
         r.manual_followup_required,
         nullif(r.manual_followup_reason, '')       as followup_reason,
         r.retry_count,
         r.parent_phone,
         r.message_preview,
         r.payment_link_url,
         r.id
    from genalpha.reminder_events r
    left join genalpha.student_details d on d.legacy_uuid = r.student_id
    left join enrollments e on e.member_id = d.member_id and e.tenant_id = 'genalpha'
   order by r.created_at desc;

revoke all on genalpha.reminder_tracker from public, anon;
grant select on genalpha.reminder_tracker to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from genalpha.reminder_tracker;
  if n <> 581 then raise exception 'tracker returns % rows, expected 581 (a fan-out?)', n; end if;

  -- the point of the migration: almost nothing should lack an amount now
  select count(*) into n from genalpha.reminder_tracker where amount_due is null;
  if n > 40 then raise exception '% rows still have no amount_due', n; end if;
  raise notice 'rows without an amount: % (was 527)', n;

  select count(*) into n from genalpha.reminder_tracker where paid_through is null;
  raise notice 'rows without a paid-through date: %', n;

  select count(distinct journey) into n from genalpha.reminder_tracker;
  if n < 4 then raise exception 'journey collapsed to % values', n; end if;
end $$;
