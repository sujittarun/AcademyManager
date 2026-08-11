-- ============================================================
-- 2026-08-11zu · State for the payment-proof nudge
-- scope: shared
--
-- A parent taps Pay Now, pays, and then has to remember to send a
-- screenshot. The ones who forget are the ones who cost a renewal, and
-- nothing currently chases them: the immediate free-form follow-up cannot
-- be delivered (no open 24-hour window — see 2026-08-11's payment_attempted
-- change), and the reminder ladder has already fired for the day.
--
-- So the nudge becomes a scheduled, conditional template send, using the
-- same shape the engine already uses for manager_payment_alert_due_at: a
-- due time on the row, a worker that drains it, and a condition that
-- cancels it if the situation resolved itself.
--
-- Four columns, all GenAlpha-only, so they go on the side table rather
-- than on shared reminder_events:
--
--   parent_proof_nudge_due_at   when to send, if still needed
--   parent_proof_nudge_status   scheduled | sent | skipped | cancelled
--   upi_app_opened_at           the page lost visibility right after the
--                               intent fired, so a UPI app really opened
--   upi_seconds_away            how long before they came back
--
-- The last two are why the delay can be short. A browser cannot see
-- whether a UPI payment succeeded — an intent gives no callback, that
-- needs a payment gateway — but it can see whether an app opened at all,
-- and for how long. Someone who never left the page did not pay. Someone
-- away for four seconds bounced. Someone away for forty was in a payment
-- flow. The nudge can say something different to each.
-- ============================================================

alter table genalpha.reminder_event_details
  add column if not exists parent_proof_nudge_due_at timestamptz,
  add column if not exists parent_proof_nudge_status text,
  add column if not exists upi_app_opened_at         timestamptz,
  add column if not exists upi_seconds_away          integer;

create index if not exists reminder_event_details_nudge_due_idx
  on genalpha.reminder_event_details (parent_proof_nudge_due_at)
  where parent_proof_nudge_status = 'scheduled';

comment on column genalpha.reminder_event_details.upi_seconds_away is
  'Seconds between the UPI intent firing and the parent returning to pay.html. Null means they never left, which means no UPI app opened.';

drop view if exists genalpha.reminder_events cascade;
create view genalpha.reminder_events with (security_invoker = true) as
 SELECT r.id::text AS id,
    d.legacy_uuid AS student_id,
    r.reminder_type,
    r.channel,
    r.status,
    r.dry_run,
    r.due_date,
    r.overdue_days,
    x.plan_options,
    x.selected_plan,
    r.amount,
    x.payment_link_url,
    x.payment_link_id,
    r.to_phone AS parent_phone,
    x.manager_phone,
    x.message_preview,
    x.help_requested,
    x.created_by,
    r.created_at,
    x.whatsapp_message_id,
    x.meta_response,
    x.meta_error,
    x.accepted_at,
    x.delivered_at,
    x.read_at,
    x.failed_at,
    x.payment_link_sent_at,
    x.payment_attempted_at,
    x.payment_pending_verification_at,
    x.payment_confirmed_at,
    x.confirmation_message_id,
    x.confirmation_sent_at,
    x.confirmation_delivered_at,
    x.confirmation_read_at,
    x.confirmation_failed_at,
    x.confirmation_meta_response,
    x.confirmation_meta_error,
    r.retry_count,
    x.max_retry_count,
    r.next_retry_at,
    x.last_retry_at,
    x.retry_reason,
    x.manual_followup_required,
    x.manager_payment_alert_status,
    x.manager_payment_alert_due_at,
    x.manager_payment_alert_sent_at,
    x.manager_payment_alert_meta_response,
    NULL::text AS manager_payment_alert_error,
    x.manual_followup_reason,
    r.stage,
    m.name AS student_name,
    m.reg_no,
    x.parent_proof_nudge_due_at,
    x.parent_proof_nudge_status,
    x.upi_app_opened_at,
    x.upi_seconds_away
   FROM reminder_events r
     LEFT JOIN genalpha.reminder_event_details x ON x.reminder_event_id = r.id
     LEFT JOIN genalpha.student_details d ON d.member_id = r.member_id
     LEFT JOIN members m ON m.id = r.member_id
  WHERE r.tenant_id = 'genalpha'::text;

revoke all on genalpha.reminder_events from public, anon;
grant select, insert, update, delete on genalpha.reminder_events to authenticated, service_role;

create trigger reminder_events_iud instead of insert or update or delete
  on genalpha.reminder_events for each row execute function genalpha.reminder_events_write();

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_events'
     and column_name in ('parent_proof_nudge_due_at','parent_proof_nudge_status',
                         'upi_app_opened_at','upi_seconds_away');
  if n <> 4 then raise exception 'only % of 4 nudge columns are exposed', n; end if;

  select count(*) into n from genalpha.reminder_events;
  if n <> 581 then raise exception 'view returns % rows, expected 581', n; end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid='genalpha.reminder_events'::regclass and not tgisinternal) then
    raise exception 'the INSTEAD OF trigger did not survive the rebuild';
  end if;

  -- the tracking columns added earlier must still be there
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_events'
     and column_name in ('student_name','reg_no','message_preview','selected_plan');
  if n <> 4 then raise exception 'the view lost its tracking columns'; end if;

  raise notice 'nudge state added; view now % columns',
    (select count(*) from information_schema.columns
      where table_schema='genalpha' and table_name='reminder_events');
end $$;
