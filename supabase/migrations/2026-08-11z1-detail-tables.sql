-- ============================================================
-- 2026-08-11z1 · Side tables for the 55 columns the merge dropped
-- scope: shared
--
-- GenAlpha's reminder_events has 49 columns and its whatsapp_flow_events
-- has 32. The merge mapped them onto the platform's shared tables, which
-- have 10 and 6, and carried nine more into wa_flow_events.meta.
-- Everything else was dropped: 38 populated columns from one, 17 from
-- the other — payment_link_url, selected_plan, plan_options, the
-- confirmation_* delivery receipts, the manager_payment_alert_* chain,
-- the retry state. That is the machinery behind a parent tapping a plan
-- in WhatsApp and paying.
--
-- Nothing is lost; it is all in the pre-merge export. But it had to be
-- found, and the reason it was not is worth writing down: every check on
-- the merge counted ROWS, and all 3,491 rows arrived. A row count cannot
-- see a row that arrived with three-quarters of its columns missing.
--
-- SHAPE. Not 55 new columns on two shared tables — that would make one
-- tenant's WhatsApp state part of the contract the other five sign.
-- PLATFORM.md already names the pattern: "Tenant-specific field -> a
-- tenant-owned table keyed on the shared row's id." The shared row stays
-- the single source of truth for what the platform reasons about (who,
-- when, how much, what stage); the side table holds the rest, and
-- cascades with it.
--
-- Data arrives in 2026-08-11z2 onward — split only because a single
-- statement this size is rejected with HTTP 413.
-- ============================================================

create table if not exists genalpha.reminder_event_details (
  reminder_event_id bigint primary key references public.reminder_events(id) on delete cascade,
  dry_run boolean,
  read_at timestamptz,
  failed_at timestamptz,
  created_by text,
  meta_error jsonb,
  accepted_at timestamptz,
  retry_count integer,
  delivered_at timestamptz,
  plan_options text[],
  retry_reason text,
  last_retry_at timestamptz,
  manager_phone text,
  meta_response jsonb,
  reminder_type text,
  selected_plan text,
  help_requested boolean,
  max_retry_count integer,
  message_preview text,
  payment_link_id text,
  payment_link_url text,
  whatsapp_message_id text,
  confirmation_read_at timestamptz,
  confirmation_sent_at timestamptz,
  payment_attempted_at timestamptz,
  payment_confirmed_at timestamptz,
  payment_link_sent_at timestamptz,
  confirmation_failed_at timestamptz,
  manual_followup_reason text,
  confirmation_message_id text,
  confirmation_meta_error jsonb,
  manual_followup_required boolean,
  confirmation_delivered_at timestamptz,
  confirmation_meta_response jsonb,
  manager_payment_alert_due_at timestamptz,
  manager_payment_alert_status text,
  manager_payment_alert_sent_at timestamptz,
  payment_pending_verification_at timestamptz,
  manager_payment_alert_meta_response jsonb
);
alter table genalpha.reminder_event_details enable row level security;
create policy reminder_event_details_staff on genalpha.reminder_event_details for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.reminder_event_details from public, anon;
grant select, insert, update, delete on genalpha.reminder_event_details to authenticated, service_role;
comment on table genalpha.reminder_event_details is
  'GenAlpha-only detail for public.reminder_events. Keyed on the shared row and cascades with it; the shared row remains the source of truth for the platform-visible fields.';

create table if not exists genalpha.wa_flow_event_details (
  flow_event_id bigint primary key references public.wa_flow_events(id) on delete cascade,
  status_at timestamptz,
  created_by text,
  proof_path text,
  delivered_at timestamptz,
  message_body text,
  message_kind text,
  parent_phone text,
  payment_plan text,
  proof_bucket text,
  error_message text,
  payment_amount numeric,
  payment_months integer,
  payment_to_date date,
  provider_payload jsonb,
  payment_from_date date,
  reminder_event_id uuid,
  payment_link_request_id uuid
);
alter table genalpha.wa_flow_event_details enable row level security;
create policy wa_flow_event_details_staff on genalpha.wa_flow_event_details for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.wa_flow_event_details from public, anon;
grant select, insert, update, delete on genalpha.wa_flow_event_details to authenticated, service_role;
comment on table genalpha.wa_flow_event_details is
  'GenAlpha-only detail for public.wa_flow_events. Keyed on the shared row and cascades with it; the shared row remains the source of truth for the platform-visible fields.';

do $$
begin
  if (select count(*) from information_schema.columns
       where table_schema='genalpha' and table_name='reminder_event_details') < 39 then
    raise exception 'reminder_event_details is missing columns';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema='genalpha' and table_name='wa_flow_event_details') < 18 then
    raise exception 'wa_flow_event_details is missing columns';
  end if;
  raise notice 'side tables created, empty; data follows';
end $$;
