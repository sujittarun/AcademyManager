-- ============================================================
-- 2026-08-11zr · Thirteen triggers the merge left behind
-- scope: shared
--
-- The player timeline stopped updating when reminders go out, and the
-- reason is that GenAlpha's database did that work in TRIGGERS, and the
-- merge brought the tables and the data but not the triggers. Thirteen of
-- them, on students, student_payments, reminder_events,
-- whatsapp_flow_events and admissions.
--
-- The timeline is written by two:
--
--   log_whatsapp_flow_event_timeline    every flow event -> a
--                                       'whatsapp_flow' timeline entry,
--                                       titled by event type and status
--   log_reminder_status_change_timeline a reminder that FAILS -> a
--                                       'whatsapp_reminder_failed' entry
--                                       carrying the provider's reason
--
-- That is where the 1,969 'whatsapp_flow' and 63 'whatsapp_reminder_failed'
-- entries in the migrated history came from, and why there have been none
-- since: 13 reminders went out today and the timeline recorded nothing.
--
-- WHERE THEY GO NOW. Not as AFTER triggers on the shared tables. The
-- fields these read — message_kind, payment_plan, payment_amount,
-- proof_path, meta_error — live in genalpha's side tables, which my
-- INSTEAD OF triggers populate AFTER the shared row is written, so an
-- AFTER trigger on wa_flow_events would fire too early and see none of
-- them.
--
-- The INSTEAD OF trigger itself receives `new` in exactly the shape the
-- original trigger expected: GenAlpha's own 32-column row. So the logic
-- goes there, unchanged in substance, reading the same field names.
--
-- This file does the two timeline triggers, which is what stopped
-- working. The other ten — the students audit/pause/updated_at set, the
-- payment lifecycle logger and the four admission-claim reconcilers — are
-- listed at the end so they are not forgotten twice.
-- ============================================================

create or replace function genalpha.whatsapp_flow_event_title(p_event_type text, p_status text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when p_event_type = 'reminder_created' then 'Fee reminder prepared'
    when p_event_type = 'reminder_send_failed' then 'Fee reminder failed to parent'
    when p_event_type = 'reminder_message_status' then
      case
        when p_status = 'delivered' then 'Fee reminder delivered to parent'
        when p_status = 'read' then 'Fee reminder read by parent'
        when p_status = 'failed' then 'Fee reminder failed to parent'
        else ''
      end
    when p_event_type = 'whatsapp_message_status' then
      case
        when p_status = 'delivered' then 'WhatsApp follow-up delivered'
        when p_status = 'read' then 'WhatsApp follow-up read'
        when p_status = 'failed' then 'WhatsApp follow-up failed'
        else ''
      end
    when p_event_type = 'confirmation_message_status' then
      case
        when p_status = 'delivered' then 'Payment confirmation delivered to parent'
        when p_status = 'read' then 'Payment confirmation read by parent'
        when p_status = 'failed' then 'Payment confirmation failed to parent'
        else ''
      end
    when p_event_type = 'manager_payment_alert_with_proof_sent' then 'Manager payment alert sent with proof'
    when p_event_type = 'manager_payment_alert_without_proof_sent' then 'Manager payment alert sent'
    when p_event_type = 'payment_verification_reply_sent' then 'Payment proof reply sent to parent'
    when p_event_type = 'parent_plan_selected' then 'Parent selected payment plan'
    when p_event_type = 'payment_link_sent' then 'Payment link sent to parent'
    when p_event_type = 'payment_attempted' then 'Parent tapped Pay Now'
    when p_event_type = 'payment_pending_verification' then 'Payment proof received from parent'
    when p_event_type = 'payment_confirmed' then 'Payment confirmed by academy'
    when p_event_type = 'parent_help_requested' then 'Parent requested help'
    else ''
  end;
$function$
;

comment on function genalpha.whatsapp_flow_event_title(text, text) is
  'Human title for a WhatsApp flow event. Ported verbatim from GenAlpha''s own database, where it fed log_whatsapp_flow_event_timeline.';
revoke execute on function genalpha.whatsapp_flow_event_title(text, text) from public, anon;
grant  execute on function genalpha.whatsapp_flow_event_title(text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- 1. Flow event -> player timeline
-- ------------------------------------------------------------
create or replace function genalpha.log_flow_event_timeline(new_row genalpha.whatsapp_flow_events)
returns void
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare v_details text; v_title text; v_happened_at timestamptz;
begin
  if new_row.student_id is null then return; end if;

  if new_row.event_type = 'whatsapp_message_status'
     and new_row.message_kind like 'manager_alert%' then
    v_title := case new_row.status
      when 'delivered' then 'Manager payment alert delivered'
      when 'read'      then 'Manager payment alert read'
      when 'failed'    then 'Manager payment alert failed'
      else '' end;
  else
    v_title := genalpha.whatsapp_flow_event_title(new_row.event_type, new_row.status);
  end if;
  if nullif(v_title, '') is null then return; end if;

  v_happened_at := coalesce(new_row.status_at, new_row.read_at, new_row.delivered_at,
                            new_row.failed_at, new_row.accepted_at, new_row.created_at, now());

  v_details := concat_ws(' • ',
    nullif(new_row.message_body, ''),
    nullif(new_row.status, ''),
    case when nullif(new_row.payment_plan,'') is not null then concat('Plan: ', new_row.payment_plan) end,
    case when new_row.payment_amount is not null
         then concat('Amount: Rs ', trim(to_char(new_row.payment_amount, 'FM999999990.00'))) end,
    case when new_row.payment_months is not null then concat('Months: ', new_row.payment_months) end,
    case when new_row.payment_from_date is not null then concat('From: ', new_row.payment_from_date) end,
    case when new_row.payment_to_date is not null then concat('To: ', new_row.payment_to_date) end,
    nullif(new_row.error_message, ''),
    case when nullif(new_row.proof_path,'') is not null then concat('payment-proofs/', new_row.proof_path) end);

  insert into genalpha.student_timeline
    (student_id, event_type, event_date, title, details, changed_by, created_at)
  values (new_row.student_id, 'whatsapp_flow', v_happened_at::date, v_title,
          coalesce(nullif(v_details,''), 'WhatsApp flow event recorded.'),
          coalesce(nullif(new_row.created_by,''), 'WhatsApp'), v_happened_at);
end $fn$;

revoke execute on function genalpha.log_flow_event_timeline(genalpha.whatsapp_flow_events) from public, anon;

-- ------------------------------------------------------------
-- 2. Wire both into the triggers that already mediate these writes
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION genalpha.wa_flow_events_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare v_member bigint; v_id bigint; v_meta jsonb;
begin
  if tg_op = 'DELETE' then
    delete from public.wa_flow_events where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;

  v_meta := jsonb_strip_nulls(jsonb_build_object(
    'channel',     new.channel,
    'error_code',  new.error_code,
    'message_id',  new.message_id,
    'direction',   new.direction,
    'event_type',  new.event_type,
    'accepted_at', new.accepted_at,
    'sent_at',     new.sent_at,
    'read_at',     new.read_at,
    'failed_at',   new.failed_at));

  if tg_op = 'INSERT' then
    insert into public.wa_flow_events (tenant_id, member_id, step, detail, meta, at)
    values ('genalpha', v_member,
            coalesce(nullif(new.flow_step,''), nullif(new.event_type,''), 'event'),
            new.status, v_meta, coalesce(new.created_at, now()))
    returning id into v_id;

    insert into genalpha.wa_flow_event_details (
      flow_event_id, reminder_event_id, payment_link_request_id, created_by,
      delivered_at, error_message, message_body, message_kind, parent_phone,
      payment_amount, payment_from_date, payment_months, payment_plan,
      payment_to_date, proof_bucket, proof_path, provider_payload, status_at)
    values (v_id, new.reminder_event_id, new.payment_link_request_id, new.created_by,
            new.delivered_at, new.error_message, new.message_body, new.message_kind,
            new.parent_phone, new.payment_amount, new.payment_from_date,
            new.payment_months, new.payment_plan, new.payment_to_date,
            new.proof_bucket, new.proof_path, new.provider_payload, new.status_at);

    new.id := v_id::text;
    -- The timeline entry GenAlpha's own database wrote from a trigger on
    -- this table. Called here rather than from an AFTER trigger on
    -- wa_flow_events because the fields it reads (message_kind,
    -- payment_plan, proof_path) live in the side table written above.
    perform genalpha.log_flow_event_timeline(new);
    return new;
  end if;

  v_id := old.id::bigint;
  update public.wa_flow_events
     set step   = coalesce(nullif(new.flow_step,''), step),
         detail = coalesce(new.status, detail),
         meta   = coalesce(meta,'{}'::jsonb) || v_meta
   where id = v_id and tenant_id = 'genalpha';

  insert into genalpha.wa_flow_event_details (
    flow_event_id, reminder_event_id, payment_link_request_id, created_by,
    delivered_at, error_message, message_body, message_kind, parent_phone,
    payment_amount, payment_from_date, payment_months, payment_plan,
    payment_to_date, proof_bucket, proof_path, provider_payload, status_at)
  values (v_id, new.reminder_event_id, new.payment_link_request_id, new.created_by,
          new.delivered_at, new.error_message, new.message_body, new.message_kind,
          new.parent_phone, new.payment_amount, new.payment_from_date,
          new.payment_months, new.payment_plan, new.payment_to_date,
          new.proof_bucket, new.proof_path, new.provider_payload, new.status_at)
  on conflict (flow_event_id) do update set
    reminder_event_id = excluded.reminder_event_id,
    payment_link_request_id = excluded.payment_link_request_id,
    created_by = excluded.created_by, delivered_at = excluded.delivered_at,
    error_message = excluded.error_message, message_body = excluded.message_body,
    message_kind = excluded.message_kind, parent_phone = excluded.parent_phone,
    payment_amount = excluded.payment_amount, payment_from_date = excluded.payment_from_date,
    payment_months = excluded.payment_months, payment_plan = excluded.payment_plan,
    payment_to_date = excluded.payment_to_date, proof_bucket = excluded.proof_bucket,
    proof_path = excluded.proof_path, provider_payload = excluded.provider_payload,
    status_at = excluded.status_at;

  -- A delivery receipt arrives as an UPDATE, and delivered/read are
  -- exactly the events the parent-facing timeline exists for.
  perform genalpha.log_flow_event_timeline(new);
  return new;
end $function$;

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

  insert into genalpha.reminder_event_details (reminder_event_id, accepted_at, confirmation_delivered_at, confirmation_failed_at, confirmation_message_id, confirmation_meta_error, confirmation_meta_response, confirmation_read_at, confirmation_sent_at, created_by, delivered_at, failed_at, help_requested, last_retry_at, manager_payment_alert_due_at, manager_payment_alert_meta_response, manager_payment_alert_sent_at, manager_payment_alert_status, manager_phone, manual_followup_reason, manual_followup_required, max_retry_count, message_preview, meta_error, meta_response, payment_attempted_at, payment_confirmed_at, payment_link_id, payment_link_sent_at, payment_link_url, payment_pending_verification_at, plan_options, read_at, retry_reason, selected_plan, whatsapp_message_id)
    values (v_id, new.accepted_at, new.confirmation_delivered_at, new.confirmation_failed_at, new.confirmation_message_id, new.confirmation_meta_error, new.confirmation_meta_response, new.confirmation_read_at, new.confirmation_sent_at, new.created_by, new.delivered_at, new.failed_at, new.help_requested, new.last_retry_at, new.manager_payment_alert_due_at, new.manager_payment_alert_meta_response, new.manager_payment_alert_sent_at, new.manager_payment_alert_status, new.manager_phone, new.manual_followup_reason, new.manual_followup_required, new.max_retry_count, new.message_preview, new.meta_error, new.meta_response, new.payment_attempted_at, new.payment_confirmed_at, new.payment_link_id, new.payment_link_sent_at, new.payment_link_url, new.payment_pending_verification_at, new.plan_options, new.read_at, new.retry_reason, new.selected_plan, new.whatsapp_message_id);

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

  insert into genalpha.reminder_event_details (reminder_event_id, accepted_at, confirmation_delivered_at, confirmation_failed_at, confirmation_message_id, confirmation_meta_error, confirmation_meta_response, confirmation_read_at, confirmation_sent_at, created_by, delivered_at, failed_at, help_requested, last_retry_at, manager_payment_alert_due_at, manager_payment_alert_meta_response, manager_payment_alert_sent_at, manager_payment_alert_status, manager_phone, manual_followup_reason, manual_followup_required, max_retry_count, message_preview, meta_error, meta_response, payment_attempted_at, payment_confirmed_at, payment_link_id, payment_link_sent_at, payment_link_url, payment_pending_verification_at, plan_options, read_at, retry_reason, selected_plan, whatsapp_message_id)
  values (v_id, new.accepted_at, new.confirmation_delivered_at, new.confirmation_failed_at, new.confirmation_message_id, new.confirmation_meta_error, new.confirmation_meta_response, new.confirmation_read_at, new.confirmation_sent_at, new.created_by, new.delivered_at, new.failed_at, new.help_requested, new.last_retry_at, new.manager_payment_alert_due_at, new.manager_payment_alert_meta_response, new.manager_payment_alert_sent_at, new.manager_payment_alert_status, new.manager_phone, new.manual_followup_reason, new.manual_followup_required, new.max_retry_count, new.message_preview, new.meta_error, new.meta_response, new.payment_attempted_at, new.payment_confirmed_at, new.payment_link_id, new.payment_link_sent_at, new.payment_link_url, new.payment_pending_verification_at, new.plan_options, new.read_at, new.retry_reason, new.selected_plan, new.whatsapp_message_id)
  on conflict (reminder_event_id) do update set
    accepted_at = excluded.accepted_at, confirmation_delivered_at = excluded.confirmation_delivered_at, confirmation_failed_at = excluded.confirmation_failed_at, confirmation_message_id = excluded.confirmation_message_id, confirmation_meta_error = excluded.confirmation_meta_error, confirmation_meta_response = excluded.confirmation_meta_response, confirmation_read_at = excluded.confirmation_read_at, confirmation_sent_at = excluded.confirmation_sent_at, created_by = excluded.created_by, delivered_at = excluded.delivered_at, failed_at = excluded.failed_at, help_requested = excluded.help_requested, last_retry_at = excluded.last_retry_at, manager_payment_alert_due_at = excluded.manager_payment_alert_due_at, manager_payment_alert_meta_response = excluded.manager_payment_alert_meta_response, manager_payment_alert_sent_at = excluded.manager_payment_alert_sent_at, manager_payment_alert_status = excluded.manager_payment_alert_status, manager_phone = excluded.manager_phone, manual_followup_reason = excluded.manual_followup_reason, manual_followup_required = excluded.manual_followup_required, max_retry_count = excluded.max_retry_count, message_preview = excluded.message_preview, meta_error = excluded.meta_error, meta_response = excluded.meta_response, payment_attempted_at = excluded.payment_attempted_at, payment_confirmed_at = excluded.payment_confirmed_at, payment_link_id = excluded.payment_link_id, payment_link_sent_at = excluded.payment_link_sent_at, payment_link_url = excluded.payment_link_url, payment_pending_verification_at = excluded.payment_pending_verification_at, plan_options = excluded.plan_options, read_at = excluded.read_at, retry_reason = excluded.retry_reason, selected_plan = excluded.selected_plan, whatsapp_message_id = excluded.whatsapp_message_id;

  return new;
end $function$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v_student uuid; v_rid bigint; v_fid text; n0 int; n int; v_title text;
begin
  select count(*) into n0 from genalpha.student_timeline;
  select legacy_uuid into v_student from genalpha.student_details limit 1;
  select max(id) into v_rid from reminder_events where tenant_id='genalpha';

  -- The titles must match GenAlpha's own wording; the app groups on them.
  if genalpha.whatsapp_flow_event_title('reminder_message_status','read')
     <> 'Fee reminder read by parent' then
    raise exception 'the title helper does not match the original wording';
  end if;
  if genalpha.whatsapp_flow_event_title('reminder_created','') <> 'Fee reminder prepared' then
    raise exception 'reminder_created title is wrong';
  end if;
  -- an unmapped event must produce NO timeline row, not a blank one
  if genalpha.whatsapp_flow_event_title('something_else','x') <> '' then
    raise exception 'an unknown event type produced a title';
  end if;

  -- THE THING THAT STOPPED WORKING: a flow event must write the timeline.
  insert into genalpha.whatsapp_flow_events
    (student_id, reminder_event_id, event_type, direction, parent_phone,
     message_kind, message_body, status, status_at, payment_from_date, created_by)
  values (v_student, v_rid, 'reminder_message_status', 'inbound', '91[redacted-phone]',
          'template', 'probe body', 'read', now(), current_date, 'system_auto')
  returning id into v_fid;

  select title into v_title from genalpha.student_timeline
   where student_id = v_student and event_type = 'whatsapp_flow'
   order by created_at desc limit 1;
  if v_title is distinct from 'Fee reminder read by parent' then
    raise exception 'the flow event wrote no timeline entry (got %)', coalesce(v_title,'nothing');
  end if;

  -- and the details must carry the body, not a placeholder
  if not exists (select 1 from genalpha.student_timeline
                  where student_id = v_student and event_type='whatsapp_flow'
                    and details like '%probe body%'
                  order by created_at desc limit 1) then
    raise exception 'the timeline entry lost the message body';
  end if;

  delete from genalpha.student_timeline
   where student_id = v_student and event_type='whatsapp_flow' and details like '%probe body%';
  delete from genalpha.whatsapp_flow_events where id = v_fid;

  select count(*) into n from genalpha.student_timeline;
  if n <> n0 then raise exception 'the probe left % timeline rows behind', n - n0; end if;

  -- History intact. Not a fixed number: 3,053 entries came from the
  -- merge and the count legitimately grows — record_fee_payment wrote one
  -- for a real renewal this morning. The floor is what matters.
  if n0 < 3053 then raise exception 'timeline lost rows: % (migrated 3053)', n0; end if;
  select count(*) into n from genalpha.whatsapp_flow_events;
  if n <> 2923 then raise exception 'flow event count is %, expected 2923', n; end if;

  raise notice 'flow events write the player timeline again; % historical entries intact', n0;
end $$;

-- ------------------------------------------------------------
-- STILL NOT PORTED, so it is written down rather than forgotten twice.
-- Ten more triggers exist on GenAlpha's own project and do not exist here:
--
--   students          set_updated_at
--                     set_student_reminder_pause_audit
--                     ensure_student_pause_billing_fields
--                     sync_whatsapp_contact_followup
--                     log_student_life_timeline          (insert + update)
--   student_payments  log_student_payment_life_timeline
--                     preserve_admission_claim_payment_values
--                     reconcile_admission_claim_from_payment
--   admissions        guard_intake_admission_type
--                     link_admission_claim_to_approved_student
--
-- log_student_life_timeline is the largest (5.5 KB) and is why profile
-- edits appear in a player's history; log_student_payment_life_timeline
-- is partly covered now, because record_fee_payment writes its own
-- timeline entry. The four admission-claim ones matter when a parent's
-- payment claim has to be matched to an approved admission.
-- ------------------------------------------------------------
