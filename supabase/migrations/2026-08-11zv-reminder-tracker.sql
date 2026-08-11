-- ============================================================
-- 2026-08-11zv · One view for the morning check
-- scope: shared
--
-- genalpha.reminder_events has 56 columns because it reproduces
-- GenAlpha's original table plus everything the merge added. That is the
-- right shape for the engine and the wrong shape for a person reading it
-- over coffee — the answer to "did today's reminders land, and did anyone
-- pay" is spread across a dozen of them.
--
-- This is that answer, in reading order: who, which rung, what it cost,
-- how far it got, and what the parent did next. One row per reminder,
-- newest first.
--
-- `journey` is the single column worth having: it collapses eight
-- timestamps into the furthest point each family actually reached, so a
-- morning scan is one column wide instead of eight.
-- ============================================================

create or replace view genalpha.reminder_tracker
with (security_invoker = true) as
  select (r.created_at at time zone 'Asia/Kolkata')::date as on_date,
         to_char(r.created_at at time zone 'Asia/Kolkata', 'HH24:MI') as at_ist,
         r.student_name,
         r.reg_no,
         r.reminder_type                           as rung,
         r.amount,
         r.due_date,
         r.overdue_days,
         r.status,

         -- how far this one actually got
         case
           when r.payment_confirmed_at is not null            then '7 paid · confirmed'
           when r.payment_pending_verification_at is not null then '6 proof received'
           when r.payment_attempted_at is not null            then '5 tapped Pay Now'
           when r.payment_link_sent_at is not null            then '4 link sent'
           when r.selected_plan is not null
            and r.selected_plan <> ''                         then '3 plan chosen'
           when r.read_at is not null                         then '2 read'
           when r.delivered_at is not null                    then '1 delivered'
           when r.accepted_at is not null                     then '0 sent'
           when r.failed_at is not null                       then 'x failed'
           else '- queued'
         end                                       as journey,

         r.selected_plan,
         -- did a UPI app actually open, and for how long
         (r.upi_app_opened_at is not null)         as opened_upi_app,
         r.upi_seconds_away,
         r.parent_proof_nudge_status               as proof_nudge,

         r.delivered_at, r.read_at,
         r.payment_link_sent_at, r.payment_attempted_at,
         r.payment_pending_verification_at, r.payment_confirmed_at,
         r.failed_at,
         nullif(r.meta_error->>'message', '')      as failure_reason,
         r.manual_followup_required,
         nullif(r.manual_followup_reason, '')      as followup_reason,
         r.retry_count,
         r.parent_phone,
         r.message_preview,
         r.payment_link_url,
         r.id
    from genalpha.reminder_events r
   order by r.created_at desc;

revoke all on genalpha.reminder_tracker from public, anon;
grant select on genalpha.reminder_tracker to authenticated, service_role;

comment on view genalpha.reminder_tracker is
  'The morning check: one row per reminder, journey collapses the eight timestamps into how far each family got. Read this, not public.reminder_events.';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v text;
begin
  select count(*) into n from genalpha.reminder_tracker;
  if n <> 581 then raise exception 'tracker returns % rows, expected 581', n; end if;

  -- journey must actually discriminate, not collapse everything to one value
  select count(distinct journey) into n from genalpha.reminder_tracker;
  if n < 4 then raise exception 'journey only takes % distinct values', n; end if;

  -- and the confirmed payments must show as such
  select count(*) into n from genalpha.reminder_tracker where journey = '7 paid · confirmed';
  if n = 0 then raise exception 'no reminder reads as confirmed, though 76 payment_confirmed rows exist'; end if;

  select count(*) into n from genalpha.reminder_tracker where student_name is null;
  if n > 0 then raise exception '% tracker rows have no player name', n; end if;

  raise notice 'reminder_tracker: % rows, % distinct journey stages',
    (select count(*) from genalpha.reminder_tracker),
    (select count(distinct journey) from genalpha.reminder_tracker);
end $$;
