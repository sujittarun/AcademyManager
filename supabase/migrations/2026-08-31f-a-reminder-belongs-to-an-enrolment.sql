-- ============================================================
-- 2026-08-31f · A GenAlpha reminder belongs to an enrolment
-- scope: shared
--
-- All 742 GenAlpha reminder_events rows carried enrollment_id = NULL, because
-- genalpha.reminder_events_write resolved member_id and nothing else. Three
-- pieces of platform machinery match on that column:
--
--   apply_payment_coverage   update reminder_events set status = 'resolved'
--                             where tenant_id = ... and enrollment_id = e.id
--   one-per-day guard        unique (tenant_id, enrollment_id, ist_date)
--   reminder_queue           "already sent today" is keyed on it too
--
-- So no payment has ever closed a GenAlpha reminder — 592 sit permanently in
-- sent/delivered/read/failed/manual_followup on cycles long since paid, and
-- `resolved` has never once been set. Both database-level guards were inert
-- for this tenant; the only thing preventing duplicate daily reminders was the
-- edge function's own check.
--
-- This does NOT fix the karthikeya incident and is not claimed to: that was
-- the unbounded Pay Now window (2026-08-31c), and payment_attempted is not in
-- apply_payment_coverage's resolve list anyway.
--
-- Backfilling enrollment_id ALONE would have violated the unique index on 498
-- rows, because the 2026-08-10 migration stamped 568 historical reminders with
-- ist_date = the import date while their created_at spans May to August.
-- Correcting ist_date to the real IST day drops the collisions from 67 groups
-- to 4 — four genuine duplicate pairs from May, all failed/read on the same
-- due date. Those four keep the newer row's enrolment and leave the older null:
-- nothing is deleted, and the index is satisfied.
-- ============================================================

-- 1. The dates the migration got wrong.
update reminder_events
   set ist_date = (created_at at time zone 'Asia/Kolkata')::date
 where tenant_id = 'genalpha'
   and ist_date <> (created_at at time zone 'Asia/Kolkata')::date;

-- 2. The enrolment each reminder belongs to, newest row per day where a
--    genuine duplicate pair would otherwise collide.
with ranked as (
  select r.id, e.id as enrollment_id,
         row_number() over (partition by r.member_id, r.ist_date
                            order by r.created_at desc, r.id desc) as rn
    from reminder_events r
    join enrollments e on e.member_id = r.member_id and e.tenant_id = 'genalpha'
   where r.tenant_id = 'genalpha' and r.status <> 'void' and r.enrollment_id is null
)
update reminder_events r
   set enrollment_id = ranked.enrollment_id
  from ranked
 where r.id = ranked.id and ranked.rn = 1;

CREATE OR REPLACE FUNCTION genalpha.reminder_events_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare v_member bigint; v_id bigint; v_enroll bigint;
begin
  if tg_op = 'DELETE' then
    -- the side row cascades
    delete from public.reminder_events where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;

  -- THE ENROLMENT IS WHAT THE PLATFORM MATCHES ON. apply_payment_coverage
  -- closes reminders with `where tenant_id = ... and enrollment_id = e.id`,
  -- and the one-reminder-per-day unique index is (tenant_id, enrollment_id,
  -- ist_date). This trigger resolved member_id and never enrollment_id, so all
  -- 742 GenAlpha reminders carried null: no payment has ever closed one, and
  -- both database-level guards were inert for this tenant.
  select e.id into v_enroll
    from enrollments e
   where e.member_id = v_member and e.tenant_id = 'genalpha'
   order by (e.status = 'active') desc, e.id desc
   limit 1;

  if tg_op = 'INSERT' then
    if v_member is null then
      raise exception 'no GenAlpha player with id %', new.student_id;
    end if;
    -- sent_by and ist_date are NOT NULL on the shared table and have no
    -- GenAlpha equivalent; created_by is the closest honest source.
    insert into public.reminder_events (
      tenant_id, member_id, enrollment_id, reminder_type, stage, channel, status, due_date,
      overdue_days, amount, to_phone, retry_count, dry_run, sent_by, ist_date,
      created_at, updated_at)
    values ('genalpha', v_member, v_enroll,
            coalesce(new.reminder_type, 'renewal'), coalesce(new.stage, 'due'),
            coalesce(new.channel, 'whatsapp'), coalesce(new.status, 'queued'),
            new.due_date, coalesce(new.overdue_days, 0), new.amount, new.parent_phone,
            coalesce(new.retry_count, 0), coalesce(new.dry_run, false),
            coalesce(nullif(new.created_by, ''), 'genalpha'),
            -- IST, not the UTC date. ist_date feeds the one-per-day guard and
            -- the "already sent today" check, and the business runs on IST
            -- calendar days; ::date on a timestamptz gives the UTC day.
            coalesce((new.created_at at time zone 'Asia/Kolkata')::date, ist_today()),
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
end $function$
;


do $$
declare v_null int; v_total int; v_dupes int; v_aug10 int;
begin
  select count(*) into v_total from reminder_events where tenant_id = 'genalpha';
  select count(*) into v_null from reminder_events
   where tenant_id = 'genalpha' and status <> 'void' and enrollment_id is null;
  -- Exactly the four May duplicate pairs may remain unlinked.
  if v_null > 4 then
    raise exception '% GenAlpha reminders still have no enrolment, expected at most 4', v_null;
  end if;

  select count(*) into v_aug10 from reminder_events
   where tenant_id = 'genalpha' and ist_date <> (created_at at time zone 'Asia/Kolkata')::date;
  if v_aug10 > 0 then
    raise exception '% reminders still carry the import date instead of their own', v_aug10;
  end if;

  -- The unique index must now actually hold for this tenant.
  select count(*) into v_dupes from (
    select 1 from reminder_events
     where tenant_id = 'genalpha' and status <> 'void' and enrollment_id is not null
     group by enrollment_id, ist_date having count(*) > 1) q;
  if v_dupes > 0 then
    raise exception '% enrolment/day pairs would violate the one-per-day guard', v_dupes;
  end if;

  if position('enrollment_id' in
      (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'genalpha' and p.proname = 'reminder_events_write')) = 0 then
    raise exception 'the writer still does not set enrollment_id';
  end if;

  raise notice 'GenAlpha reminders: % rows, % unlinked (the May duplicate pairs)', v_total, v_null;
end $$;
