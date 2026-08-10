-- ============================================================
-- 2026-08-11zb · The views only showed a quarter of what the app reads
-- scope: shared
--
-- 2026-08-11z restored 55 dropped columns into two side tables, but the
-- views GenAlpha's app actually queries still exposed only the 10 and 6
-- that survived the merge. Restoring data without exposing it leaves it
-- inert.
--
-- This is not theoretical. GenAlpha's app selects, by name:
--
--   reminder_events: selected_plan, payment_link_url, meta_response,
--     meta_error, created_by, failed_at, max_retry_count, next_retry_at,
--     last_retry_at, retry_reason, manual_followup_required,
--     manual_followup_reason
--
-- Every one of those was dropped by the merge. PostgREST returns a 400
-- for an unknown column, so those three queries have been failing since
-- the cutover — the reminder history and retry screens, which are how
-- staff see whether a family was actually messaged.
--
-- The views now expose all 49 and all 32 original columns, assembled
-- from the shared row plus the side table. Two columns
-- (manager_payment_alert_error, admission_id) are exposed as NULL: they
-- were empty in every archived row, so there was nothing to restore, and
-- a missing column breaks a query where a null one does not.
--
-- INSTEAD OF triggers make them writable again. Without them the app and
-- GenAlpha's reminder engine can read but not write, and a reminder
-- engine that cannot record what it sent will send it again.
-- ============================================================

drop view if exists genalpha.reminder_events cascade;
create view genalpha.reminder_events with (security_invoker = true) as
  select r.id::text as id,
         d.legacy_uuid as student_id,
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
         r.to_phone as parent_phone,
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
         null::text as manager_payment_alert_error,
         x.manual_followup_reason,
         -- not a GenAlpha column. The pre-merge platform view exposed it,
         -- so leaving it out would be a second regression on top of the
         -- one this file fixes. The view is a superset of both surfaces.
         r.stage
    from public.reminder_events r
    left join genalpha.reminder_event_details x on x.reminder_event_id = r.id
    left join genalpha.student_details d on d.member_id = r.member_id
   where r.tenant_id = 'genalpha';

drop view if exists genalpha.whatsapp_flow_events cascade;
create view genalpha.whatsapp_flow_events with (security_invoker = true) as
  select w.id::text as id,
         w.step as flow_step,
         d.legacy_uuid as student_id,
         null::uuid as admission_id,
         x.reminder_event_id,
         x.payment_link_request_id,
         w.meta->>'event_type' as event_type,
         w.meta->>'direction' as direction,
         w.meta->>'channel' as channel,
         x.parent_phone,
         x.message_kind,
         x.message_body,
         w.meta->>'message_id' as message_id,
         w.detail as status,
         x.status_at,
         (w.meta->>'sent_at')::timestamptz as sent_at,
         (w.meta->>'accepted_at')::timestamptz as accepted_at,
         x.delivered_at,
         (w.meta->>'read_at')::timestamptz as read_at,
         (w.meta->>'failed_at')::timestamptz as failed_at,
         w.meta->>'error_code' as error_code,
         x.error_message,
         x.payment_plan,
         x.payment_amount,
         x.payment_months,
         x.payment_from_date,
         x.payment_to_date,
         x.proof_bucket,
         x.proof_path,
         x.provider_payload,
         x.created_by,
         w.at as created_at
    from public.wa_flow_events w
    left join genalpha.wa_flow_event_details x on x.flow_event_id = w.id
    left join genalpha.student_details d on d.member_id = w.member_id
   where w.tenant_id = 'genalpha';

revoke all on genalpha.reminder_events, genalpha.whatsapp_flow_events from public, anon;
grant select, insert, update, delete
   on genalpha.reminder_events, genalpha.whatsapp_flow_events
   to authenticated, service_role;

-- ------------------------------------------------------------
-- Writable again
-- ------------------------------------------------------------
create or replace function genalpha.reminder_events_write()
returns trigger language plpgsql security definer set search_path = genalpha, public as $fn$
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
end $fn$;

create trigger reminder_events_iud instead of insert or update or delete
  on genalpha.reminder_events for each row execute function genalpha.reminder_events_write();

create or replace function genalpha.wa_flow_events_write()
returns trigger language plpgsql security definer set search_path = genalpha, public as $fn$
declare v_member bigint; v_id bigint;
begin
  if tg_op = 'DELETE' then
    delete from public.wa_flow_events where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;

  if tg_op = 'INSERT' then
    insert into public.wa_flow_events (tenant_id, member_id, step, detail, meta, at)
    values ('genalpha', v_member,
            coalesce(new.flow_step, 'event'), new.status,
            -- the nine fields the merge folded into meta stay there, so
            -- the view keeps reading them from one place
            jsonb_strip_nulls(coalesce(new.meta, '{}'::jsonb) || jsonb_build_object(
              'channel', new.channel, 'error_code', new.error_code,
              'message_id', new.message_id, 'direction', new.direction,
              'event_type', new.event_type, 'accepted_at', new.accepted_at,
              'sent_at', new.sent_at, 'read_at', new.read_at, 'failed_at', new.failed_at)),
            coalesce(new.created_at, now()))
    returning id into v_id;

    insert into genalpha.wa_flow_event_details (flow_event_id, created_by, delivered_at, error_message, message_body, message_kind, parent_phone, payment_amount, payment_from_date, payment_link_request_id, payment_months, payment_plan, payment_to_date, proof_bucket, proof_path, provider_payload, reminder_event_id, status_at)
    values (v_id, new.created_by, new.delivered_at, new.error_message, new.message_body, new.message_kind, new.parent_phone, new.payment_amount, new.payment_from_date, new.payment_link_request_id, new.payment_months, new.payment_plan, new.payment_to_date, new.proof_bucket, new.proof_path, new.provider_payload, new.reminder_event_id, new.status_at);

    new.id := v_id::text;
    return new;
  end if;

  v_id := old.id::bigint;
  update public.wa_flow_events
     set step = coalesce(new.flow_step, step),
         detail = new.status,
         meta = jsonb_strip_nulls(coalesce(new.meta, meta) || jsonb_build_object(
           'channel', new.channel, 'error_code', new.error_code,
           'message_id', new.message_id, 'direction', new.direction,
           'event_type', new.event_type, 'accepted_at', new.accepted_at,
           'sent_at', new.sent_at, 'read_at', new.read_at, 'failed_at', new.failed_at))
   where id = v_id and tenant_id = 'genalpha';

  insert into genalpha.wa_flow_event_details (flow_event_id, created_by, delivered_at, error_message, message_body, message_kind, parent_phone, payment_amount, payment_from_date, payment_link_request_id, payment_months, payment_plan, payment_to_date, proof_bucket, proof_path, provider_payload, reminder_event_id, status_at)
  values (v_id, new.created_by, new.delivered_at, new.error_message, new.message_body, new.message_kind, new.parent_phone, new.payment_amount, new.payment_from_date, new.payment_link_request_id, new.payment_months, new.payment_plan, new.payment_to_date, new.proof_bucket, new.proof_path, new.provider_payload, new.reminder_event_id, new.status_at)
  on conflict (flow_event_id) do update set
    created_by = excluded.created_by, delivered_at = excluded.delivered_at, error_message = excluded.error_message, message_body = excluded.message_body, message_kind = excluded.message_kind, parent_phone = excluded.parent_phone, payment_amount = excluded.payment_amount, payment_from_date = excluded.payment_from_date, payment_link_request_id = excluded.payment_link_request_id, payment_months = excluded.payment_months, payment_plan = excluded.payment_plan, payment_to_date = excluded.payment_to_date, proof_bucket = excluded.proof_bucket, proof_path = excluded.proof_path, provider_payload = excluded.provider_payload, reminder_event_id = excluded.reminder_event_id, status_at = excluded.status_at;

  return new;
end $fn$;

create trigger wa_flow_events_iud instead of insert or update or delete
  on genalpha.whatsapp_flow_events for each row execute function genalpha.wa_flow_events_write();

revoke execute on function genalpha.reminder_events_write() from public, anon;
revoke execute on function genalpha.wa_flow_events_write()  from public, anon;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v_id text; v_student uuid; v_before int;
begin
  -- Every original column is back, by name and by count. 50, not 49:
  -- GenAlpha's 49 plus `stage`, which the pre-merge platform view
  -- exposed and which dropping would be a second regression.
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_events';
  if n <> 50 then raise exception 'reminder_events view has % columns, expected 50', n; end if;

  -- and specifically the twelve the app selects and could not get
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_events'
     and column_name in ('reminder_type','selected_plan','payment_link_url','meta_response',
                         'meta_error','created_by','failed_at','max_retry_count','next_retry_at',
                         'last_retry_at','retry_reason','manual_followup_required');
  if n <> 12 then
    raise exception 'only % of the 12 columns the app selects are exposed', n;
  end if;
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='whatsapp_flow_events';
  if n <> 32 then raise exception 'whatsapp_flow_events view has % columns, expected 32', n; end if;

  -- Row counts unchanged: a left join that fans out would inflate them.
  select count(*) into n from genalpha.reminder_events;
  if n <> 568 then raise exception 'reminder_events view returns % rows, expected 568', n; end if;
  select count(*) into n from genalpha.whatsapp_flow_events;
  if n <> 2923 then raise exception 'flow view returns % rows, expected 2923', n; end if;

  -- THE POINT: the columns the app selects must carry values, not just
  -- exist. A view of 49 nulls satisfies every check above.
  select count(*) into n from genalpha.reminder_events where coalesce(payment_link_url,'') <> '';
  if n = 0 then raise exception 'payment_link_url is empty through the view'; end if;
  select count(*) into n from genalpha.reminder_events where coalesce(selected_plan,'') <> '';
  if n = 0 then raise exception 'selected_plan is empty through the view'; end if;
  select count(*) into n from genalpha.reminder_events where reminder_type <> 'renewal';
  if n < 200 then raise exception 'the reminder ladder did not survive into the view'; end if;

  -- Writable, end to end, then cleaned up. This is the half a schema
  -- check cannot see: the triggers either work or the reminder engine
  -- silently stops recording what it sent.
  select legacy_uuid into v_student from genalpha.student_details limit 1;
  select count(*) into v_before from public.reminder_events where tenant_id='genalpha';

  insert into genalpha.reminder_events
    (student_id, reminder_type, stage, channel, status, due_date, amount,
     selected_plan, payment_link_url, created_by)
  values (v_student, 'heads_up', 'due', 'whatsapp', 'queued', current_date, 3500,
          'quarterly', 'https://example.invalid/pay/probe', 'migration-probe')
  returning id into v_id;

  if v_id is null then raise exception 'insert through the view returned no id'; end if;

  -- it must land in BOTH halves
  if not exists (select 1 from public.reminder_events
                  where id = v_id::bigint and tenant_id='genalpha' and reminder_type='heads_up') then
    raise exception 'the shared half of the insert is missing';
  end if;
  if not exists (select 1 from genalpha.reminder_event_details
                  where reminder_event_id = v_id::bigint and selected_plan='quarterly') then
    raise exception 'the detail half of the insert is missing';
  end if;
  -- and read back as one row
  if not exists (select 1 from genalpha.reminder_events
                  where id = v_id and payment_link_url like '%probe%' and reminder_type='heads_up') then
    raise exception 'the two halves do not read back as one row';
  end if;

  update genalpha.reminder_events set status='sent', retry_reason='probe-update' where id = v_id;
  if not exists (select 1 from genalpha.reminder_events
                  where id = v_id and status='sent' and retry_reason='probe-update') then
    raise exception 'update through the view did not reach both halves';
  end if;

  delete from genalpha.reminder_events where id = v_id;
  if exists (select 1 from public.reminder_events where id = v_id::bigint) then
    raise exception 'delete through the view left the shared row behind';
  end if;
  if exists (select 1 from genalpha.reminder_event_details where reminder_event_id = v_id::bigint) then
    raise exception 'delete left an orphaned detail row — the cascade is not working';
  end if;

  select count(*) into n from public.reminder_events where tenant_id='genalpha';
  if n <> v_before then raise exception 'the probe left % extra rows behind', n - v_before; end if;

  -- No other tenant's reminders became visible through a genalpha view.
  select count(*) into n from public.reminder_events r
    join genalpha.reminder_events g on g.id = r.id::text
   where r.tenant_id <> 'genalpha';
  if n <> 0 then raise exception 'the view exposes % rows from another tenant', n; end if;

  raise notice 'views restored to full width and proven writable in both halves';
end $$;
