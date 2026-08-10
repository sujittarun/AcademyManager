-- ============================================================
-- 2026-08-11n · Rebuild the admission-AI tables with their real columns
-- scope: shared
--
-- 2026-08-10p stored these seven as {id, student_id, data jsonb,
-- created_at}, arguing that LLM output and webhook payloads change shape
-- and freezing them into DDL buys nothing.
--
-- That reasoning was wrong in the way that matters: the ONLY consumer of
-- these tables is the admission-intake edge function, 107 KB of tested
-- Deno that reads them by their real column names —
-- admission_intake_sessions.draft, .state, admission_ai_extractions'
-- confidence fields, and so on. A jsonb blob is archival, not runnable.
-- The function cannot be deployed against it, and rewriting 84 KB of
-- working conversation logic to read jsonb would be the wrong end to
-- change.
--
-- So the shapes come back, taken from the source project's
-- information_schema rather than guessed: 29 columns on sessions, 24 on
-- payment_claims, 18 on messages, and so on.
--
-- Data is re-inserted from the archive, not from the jsonb copies, so a
-- lossy round-trip cannot hide in the middle.
-- ============================================================

-- ------------------------------------------------------------
-- Sequences first. admission_intake_sessions.display_id defaults to
-- nextval('genalpha.admission_intake_display_seq'), so the table cannot be created
-- without it — the first attempt failed on exactly that. Restarted at the
-- source's current value so display ids continue rather than collide.
-- ------------------------------------------------------------
create sequence if not exists genalpha.admission_intake_display_seq start with 61;
create sequence if not exists genalpha.admissions_reg_no_seq start with 8;
create sequence if not exists genalpha.whatsapp_flow_events_flow_step_seq start with 3124;

-- admission_ai_extractions: 76 rows, 13 real columns
drop table if exists genalpha.admission_ai_extractions cascade;
create table genalpha.admission_ai_extractions (
  id uuid default gen_random_uuid(),
  session_id uuid not null,
  version integer not null,
  model text not null,
  prompt_version text not null,
  provider_response_id text default ''::text,
  source_message_ids text[] default '{}'::uuid[],
  extracted_data jsonb not null,
  conflicts jsonb default '[]'::jsonb,
  missing_fields text[] default '{}'::text[],
  overall_confidence numeric,
  created_at timestamptz default now(),
  provider_usage jsonb default '{}'::jsonb
);
alter table genalpha.admission_ai_extractions enable row level security;
create policy admission_ai_extractions_staff on genalpha.admission_ai_extractions for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admission_ai_extractions from public, anon;
grant select, insert, update, delete on genalpha.admission_ai_extractions to authenticated, service_role;

-- admission_intake_corrections: 13 rows, 10 real columns
drop table if exists genalpha.admission_intake_corrections cascade;
create table genalpha.admission_intake_corrections (
  id uuid default gen_random_uuid(),
  session_id uuid not null,
  provider_message_id text default ''::text,
  correction_text text not null,
  before_draft jsonb not null,
  patch jsonb not null,
  after_draft jsonb not null,
  interpreted_by text default 'AI'::text,
  created_by text default 'WhatsApp staff'::text,
  created_at timestamptz default now()
);
alter table genalpha.admission_intake_corrections enable row level security;
create policy admission_intake_corrections_staff on genalpha.admission_intake_corrections for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admission_intake_corrections from public, anon;
grant select, insert, update, delete on genalpha.admission_intake_corrections to authenticated, service_role;

-- admission_intake_messages: 123 rows, 18 real columns
drop table if exists genalpha.admission_intake_messages cascade;
create table genalpha.admission_intake_messages (
  id uuid default gen_random_uuid(),
  session_id uuid,
  provider_message_id text not null,
  source_chat_id text default ''::text,
  source_sender_id text default ''::text,
  source_sender_name text default ''::text,
  reply_to_provider_message_id text default ''::text,
  message_type text default 'text'::text,
  text_body text default ''::text,
  media_id text default ''::text,
  media_mime_type text default ''::text,
  media_filename text default ''::text,
  storage_bucket text default ''::text,
  storage_path text default ''::text,
  message_timestamp timestamptz default now(),
  raw_payload jsonb default '{}'::jsonb,
  processing_status text default 'received'::text,
  created_at timestamptz default now()
);
alter table genalpha.admission_intake_messages enable row level security;
create policy admission_intake_messages_staff on genalpha.admission_intake_messages for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admission_intake_messages from public, anon;
grant select, insert, update, delete on genalpha.admission_intake_messages to authenticated, service_role;

-- admission_intake_reply_interpretations: 24 rows, 16 real columns
drop table if exists genalpha.admission_intake_reply_interpretations cascade;
create table genalpha.admission_intake_reply_interpretations (
  id uuid default gen_random_uuid(),
  session_id uuid not null,
  message_id uuid,
  provider_message_id text default ''::text,
  message_text text default ''::text,
  deterministic_intent text default 'unknown'::text,
  model_intent text default ''::text,
  final_intent text not null,
  confidence numeric default 0,
  mentioned_plan text default ''::text,
  contains_new_facts boolean default false,
  reason text default ''::text,
  model text default ''::text,
  provider_response_id text default ''::text,
  provider_usage jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
alter table genalpha.admission_intake_reply_interpretations enable row level security;
create policy admission_intake_reply_interpretations_staff on genalpha.admission_intake_reply_interpretations for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admission_intake_reply_interpretations from public, anon;
grant select, insert, update, delete on genalpha.admission_intake_reply_interpretations to authenticated, service_role;

-- admission_intake_sessions: 45 rows, 29 real columns
drop table if exists genalpha.admission_intake_sessions cascade;
create table genalpha.admission_intake_sessions (
  id uuid default gen_random_uuid(),
  display_id text default ((('GACA-AI-'::text || to_char((CURRENT_DATE)::timestamp with time zone, 'YYYY'::text)) || '-'::text) || lpad((nextval('genalpha.admission_intake_display_seq'::regclass))::text, 4, '0'::text)),
  channel text not null,
  source_chat_id text default ''::text,
  source_sender_id text default ''::text,
  source_sender_name text default ''::text,
  provider_session_key text,
  status text default 'collecting'::text,
  draft jsonb default '{}'::jsonb,
  conflicts jsonb default '[]'::jsonb,
  missing_fields text[] default '{}'::text[],
  overall_confidence numeric,
  extraction_version integer default 0,
  confirmation_message_id text default ''::text,
  confirmed_by text default ''::text,
  confirmed_at timestamptz,
  opened_at timestamptz default now(),
  last_message_at timestamptz default now(),
  expires_at timestamptz default (now() + '24:00:00'::interval),
  error_code text default ''::text,
  error_message text default ''::text,
  created_by text default 'Admission intake'::text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  admission_id uuid,
  intake_type text default 'admission'::text,
  matched_student_id uuid,
  matched_student_snapshot jsonb default '{}'::jsonb,
  renewal_payment_id uuid
);
alter table genalpha.admission_intake_sessions enable row level security;
create policy admission_intake_sessions_staff on genalpha.admission_intake_sessions for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admission_intake_sessions from public, anon;
grant select, insert, update, delete on genalpha.admission_intake_sessions to authenticated, service_role;

-- admission_payment_claims: 4 rows, 24 real columns
drop table if exists genalpha.admission_payment_claims cascade;
create table genalpha.admission_payment_claims (
  id uuid default gen_random_uuid(),
  session_id uuid not null,
  admission_id uuid,
  student_id uuid,
  student_payment_id uuid,
  amount numeric default 0,
  payment_date date,
  payment_time time without time zone,
  payment_method text default ''::text,
  payment_reference text default ''::text,
  utr text default ''::text,
  payer_name text default ''::text,
  receiver_name text default ''::text,
  screenshot_status text default 'unknown'::text,
  verification_status text default 'pending'::text,
  confidence numeric,
  proof_bucket text default ''::text,
  proof_path text default ''::text,
  extracted_data jsonb default '{}'::jsonb,
  verified_by text default ''::text,
  verified_at timestamptz,
  rejection_reason text default ''::text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table genalpha.admission_payment_claims enable row level security;
create policy admission_payment_claims_staff on genalpha.admission_payment_claims for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admission_payment_claims from public, anon;
grant select, insert, update, delete on genalpha.admission_payment_claims to authenticated, service_role;

-- payment_link_requests: 76 rows, 19 real columns
drop table if exists genalpha.payment_link_requests cascade;
create table genalpha.payment_link_requests (
  id uuid default gen_random_uuid(),
  reminder_event_id uuid,
  student_id uuid not null,
  payment_type text default 'renewal'::text,
  plan_type text default 'awaiting_parent_choice'::text,
  months_covered integer default 0,
  amount numeric default 0,
  cycle_start_date date,
  provider text default 'upi'::text,
  status text default 'dry_run'::text,
  dry_run boolean default true,
  payment_link_url text,
  payment_link_id text,
  created_by text default 'System'::text,
  created_at timestamptz default now(),
  payment_link_sent_at timestamptz,
  payment_attempted_at timestamptz,
  payment_pending_verification_at timestamptz,
  payment_confirmed_at timestamptz
);
alter table genalpha.payment_link_requests enable row level security;
create policy payment_link_requests_staff on genalpha.payment_link_requests for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.payment_link_requests from public, anon;
grant select, insert, update, delete on genalpha.payment_link_requests to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from genalpha.admission_ai_extractions;
  if n <> 0 then raise exception 'admission_ai_extractions should be empty before the reload, has %', n; end if;
  select count(*) into n from genalpha.admission_intake_corrections;
  if n <> 0 then raise exception 'admission_intake_corrections should be empty before the reload, has %', n; end if;
  select count(*) into n from genalpha.admission_intake_messages;
  if n <> 0 then raise exception 'admission_intake_messages should be empty before the reload, has %', n; end if;
  select count(*) into n from genalpha.admission_intake_reply_interpretations;
  if n <> 0 then raise exception 'admission_intake_reply_interpretations should be empty before the reload, has %', n; end if;
  select count(*) into n from genalpha.admission_intake_sessions;
  if n <> 0 then raise exception 'admission_intake_sessions should be empty before the reload, has %', n; end if;
  select count(*) into n from genalpha.admission_payment_claims;
  if n <> 0 then raise exception 'admission_payment_claims should be empty before the reload, has %', n; end if;
  select count(*) into n from genalpha.payment_link_requests;
  if n <> 0 then raise exception 'payment_link_requests should be empty before the reload, has %', n; end if;
  raise notice 'shapes rebuilt; reload follows in 2026-08-11p';
end $$;
