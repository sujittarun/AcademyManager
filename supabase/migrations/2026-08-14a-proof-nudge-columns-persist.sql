-- ============================================================
-- 2026-08-14a · The proof-nudge columns were never persisted
-- scope: shared
--
-- 2026-08-11zu added parent_proof_nudge_due_at / _status and the two UPI
-- signal columns to genalpha.reminder_event_details, exposed them on the
-- genalpha.reminder_events view, and asserted all four were readable. They
-- are. What it did not do was teach the view's INSTEAD OF writer to carry
-- them, and it re-attached the old reminder_events_write() unchanged.
--
-- So every write of those four columns has been silently dropped since the
-- cutover. The engine sets parent_proof_nudge_status = 'scheduled' the
-- moment a parent taps Pay Now; the row keeps NULL, the nudge worker's
-- queue is permanently empty, and no parent has ever been asked for the
-- screenshot that a renewal depends on. Confirmed in production: every
-- reminder_events row, including today's taps, has NULL in all four.
--
-- This replaces the writer with the same body plus those four columns in
-- the insert lists, the values lists and the on-conflict update. Nothing
-- else about it changes.
-- ============================================================

CREATE OR REPLACE FUNCTION genalpha.reminder_events_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare v_member bigint; v_id bigint;
begin
  if tg_op = 'DELETE' then
    -- the side row cascades
    delete from public.reminder_events where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;

  if tg_op = 'INSERT' then
    if v_member is null then
      raise exception 'no GenAlpha player with id %', new.student_id;
    end if;
    -- sent_by and ist_date are NOT NULL on the shared table and have no
    -- GenAlpha equivalent; created_by is the closest honest source.
    insert into public.reminder_events (
      tenant_id, member_id, reminder_type, stage, channel, status, due_date,
      overdue_days, amount, to_phone, retry_count, dry_run, sent_by, ist_date,
      created_at, updated_at)
    values ('genalpha', v_member,
            coalesce(new.reminder_type, 'renewal'), coalesce(new.stage, 'due'),
            coalesce(new.channel, 'whatsapp'), coalesce(new.status, 'queued'),
            new.due_date, coalesce(new.overdue_days, 0), new.amount, new.parent_phone,
            coalesce(new.retry_count, 0), coalesce(new.dry_run, false),
            coalesce(nullif(new.created_by, ''), 'genalpha'),
            coalesce(new.created_at::date, ist_today()),
            coalesce(new.created_at, now()), now())
    returning id into v_id;

    -- log_reminder_status_change_timeline, ported. Only failures reach the
  -- player timeline: GenAlpha deliberately kept retry_scheduled out of it
  -- so a profile is not buried under every 5/30/60-minute retry.
  if new.status is distinct from old.status
     and new.status in ('failed','send_failed','delivery_failed','undelivered')
     and new.student_id is not null then
    insert into genalpha.student_timeline
      (student_id, event_type, event_date, title, details, changed_by)
    values (new.student_id, 'whatsapp_reminder_failed',
            coalesce(new.failed_at, now())::date, 'Reminder failed',
            concat('Status: ', new.status, ' • Reason: ', coalesce(
              nullif(new.meta_error->>'message',''),
              nullif(new.meta_error->'error'->>'message',''),
              nullif(new.meta_error->'error'->'error_data'->>'details',''),
              nullif(new.retry_reason,''),
              'Provider did not return a detailed reason.')),
            coalesce(nullif(new.created_by,''), 'WhatsApp'));
  end if;

  insert into genalpha.reminder_event_details (reminder_event_id, parent_proof_nudge_due_at, parent_proof_nudge_status, upi_app_opened_at, upi_seconds_away, accepted_at, confirmation_delivered_at, confirmation_failed_at, confirmation_message_id, confirmation_meta_error, confirmation_meta_response, confirmation_read_at, confirmation_sent_at, created_by, delivered_at, failed_at, help_requested, last_retry_at, manager_payment_alert_due_at, manager_payment_alert_meta_response, manager_payment_alert_sent_at, manager_payment_alert_status, manager_phone, manual_followup_reason, manual_followup_required, max_retry_count, message_preview, meta_error, meta_response, payment_attempted_at, payment_confirmed_at, payment_link_id, payment_link_sent_at, payment_link_url, payment_pending_verification_at, plan_options, read_at, retry_reason, selected_plan, whatsapp_message_id)
    values (v_id, new.parent_proof_nudge_due_at, new.parent_proof_nudge_status, new.upi_app_opened_at, new.upi_seconds_away, new.accepted_at, new.confirmation_delivered_at, new.confirmation_failed_at, new.confirmation_message_id, new.confirmation_meta_error, new.confirmation_meta_response, new.confirmation_read_at, new.confirmation_sent_at, new.created_by, new.delivered_at, new.failed_at, new.help_requested, new.last_retry_at, new.manager_payment_alert_due_at, new.manager_payment_alert_meta_response, new.manager_payment_alert_sent_at, new.manager_payment_alert_status, new.manager_phone, new.manual_followup_reason, new.manual_followup_required, new.max_retry_count, new.message_preview, new.meta_error, new.meta_response, new.payment_attempted_at, new.payment_confirmed_at, new.payment_link_id, new.payment_link_sent_at, new.payment_link_url, new.payment_pending_verification_at, new.plan_options, new.read_at, new.retry_reason, new.selected_plan, new.whatsapp_message_id);

    new.id := v_id::text;
    return new;
  end if;

  v_id := old.id::bigint;
  update public.reminder_events
     set stage = coalesce(new.stage, stage),
         channel = coalesce(new.channel, channel),
         status = coalesce(new.status, status),
         due_date = new.due_date,
         overdue_days = coalesce(new.overdue_days, overdue_days),
         amount = new.amount,
         to_phone = coalesce(new.parent_phone, to_phone),
         reminder_type = coalesce(new.reminder_type, reminder_type),
         dry_run = coalesce(new.dry_run, dry_run),
         retry_count = coalesce(new.retry_count, retry_count),
         updated_at = now()
   where id = v_id and tenant_id = 'genalpha';

  insert into genalpha.reminder_event_details (reminder_event_id, parent_proof_nudge_due_at, parent_proof_nudge_status, upi_app_opened_at, upi_seconds_away, accepted_at, confirmation_delivered_at, confirmation_failed_at, confirmation_message_id, confirmation_meta_error, confirmation_meta_response, confirmation_read_at, confirmation_sent_at, created_by, delivered_at, failed_at, help_requested, last_retry_at, manager_payment_alert_due_at, manager_payment_alert_meta_response, manager_payment_alert_sent_at, manager_payment_alert_status, manager_phone, manual_followup_reason, manual_followup_required, max_retry_count, message_preview, meta_error, meta_response, payment_attempted_at, payment_confirmed_at, payment_link_id, payment_link_sent_at, payment_link_url, payment_pending_verification_at, plan_options, read_at, retry_reason, selected_plan, whatsapp_message_id)
  values (v_id, new.parent_proof_nudge_due_at, new.parent_proof_nudge_status, new.upi_app_opened_at, new.upi_seconds_away, new.accepted_at, new.confirmation_delivered_at, new.confirmation_failed_at, new.confirmation_message_id, new.confirmation_meta_error, new.confirmation_meta_response, new.confirmation_read_at, new.confirmation_sent_at, new.created_by, new.delivered_at, new.failed_at, new.help_requested, new.last_retry_at, new.manager_payment_alert_due_at, new.manager_payment_alert_meta_response, new.manager_payment_alert_sent_at, new.manager_payment_alert_status, new.manager_phone, new.manual_followup_reason, new.manual_followup_required, new.max_retry_count, new.message_preview, new.meta_error, new.meta_response, new.payment_attempted_at, new.payment_confirmed_at, new.payment_link_id, new.payment_link_sent_at, new.payment_link_url, new.payment_pending_verification_at, new.plan_options, new.read_at, new.retry_reason, new.selected_plan, new.whatsapp_message_id)
  on conflict (reminder_event_id) do update set
    parent_proof_nudge_due_at = excluded.parent_proof_nudge_due_at, parent_proof_nudge_status = excluded.parent_proof_nudge_status, upi_app_opened_at = excluded.upi_app_opened_at, upi_seconds_away = excluded.upi_seconds_away, accepted_at = excluded.accepted_at, confirmation_delivered_at = excluded.confirmation_delivered_at, confirmation_failed_at = excluded.confirmation_failed_at, confirmation_message_id = excluded.confirmation_message_id, confirmation_meta_error = excluded.confirmation_meta_error, confirmation_meta_response = excluded.confirmation_meta_response, confirmation_read_at = excluded.confirmation_read_at, confirmation_sent_at = excluded.confirmation_sent_at, created_by = excluded.created_by, delivered_at = excluded.delivered_at, failed_at = excluded.failed_at, help_requested = excluded.help_requested, last_retry_at = excluded.last_retry_at, manager_payment_alert_due_at = excluded.manager_payment_alert_due_at, manager_payment_alert_meta_response = excluded.manager_payment_alert_meta_response, manager_payment_alert_sent_at = excluded.manager_payment_alert_sent_at, manager_payment_alert_status = excluded.manager_payment_alert_status, manager_phone = excluded.manager_phone, manual_followup_reason = excluded.manual_followup_reason, manual_followup_required = excluded.manual_followup_required, max_retry_count = excluded.max_retry_count, message_preview = excluded.message_preview, meta_error = excluded.meta_error, meta_response = excluded.meta_response, payment_attempted_at = excluded.payment_attempted_at, payment_confirmed_at = excluded.payment_confirmed_at, payment_link_id = excluded.payment_link_id, payment_link_sent_at = excluded.payment_link_sent_at, payment_link_url = excluded.payment_link_url, payment_pending_verification_at = excluded.payment_pending_verification_at, plan_options = excluded.plan_options, read_at = excluded.read_at, retry_reason = excluded.retry_reason, selected_plan = excluded.selected_plan, whatsapp_message_id = excluded.whatsapp_message_id;

  return new;
end $function$;


-- ------------------------------------------------------------
-- Checks: a write must survive a round trip through the view.
-- ------------------------------------------------------------
do $$
declare
  v_id text;
  v_status text;
  v_due timestamptz;
begin
  select id into v_id from genalpha.reminder_events order by created_at desc limit 1;
  if v_id is null then
    raise notice 'no reminder_events rows to prove the round trip against';
    return;
  end if;

  update genalpha.reminder_events
     set parent_proof_nudge_status = '__roundtrip__',
         parent_proof_nudge_due_at = timestamptz '2001-01-01 00:00:00+00'
   where id = v_id;

  select parent_proof_nudge_status, parent_proof_nudge_due_at
    into v_status, v_due
    from genalpha.reminder_events where id = v_id;

  if v_status is distinct from '__roundtrip__' then
    raise exception 'the writer still drops parent_proof_nudge_status (read back %)', v_status;
  end if;
  if v_due is distinct from timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'the writer still drops parent_proof_nudge_due_at (read back %)', v_due;
  end if;

  -- leave the row exactly as it was found
  update genalpha.reminder_events
     set parent_proof_nudge_status = null,
         parent_proof_nudge_due_at = null
   where id = v_id;

  raise notice 'proof-nudge columns now survive a write through the view';
end $$;
