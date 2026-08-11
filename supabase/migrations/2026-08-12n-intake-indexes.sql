-- ============================================================
-- 2026-08-12n · Seven uniqueness guarantees the migration dropped
-- scope: shared
--
-- Comparing indexes was meant to be a performance check. It is not: of
-- the 50 legacy indexes, the ones missing on tables that moved UNCHANGED
-- include seven UNIQUE indexes, and a unique index is a correctness
-- constraint wearing a performance costume. Each of these was the only
-- thing preventing a specific duplicate:
--
--   admission_intake_messages(provider_message_id)
--       THE WHATSAPP DEDUP KEY. ingestMessage() inserts and, only when
--       the insert comes back empty, looks up the existing row and
--       returns {duplicate: true}. That branch is reachable ONLY because
--       the unique index rejects the second insert. Without it Meta's
--       webhook retries — which happen on any non-2xx — append the same
--       parent message again, and AgentAlpha reads a conversation with
--       every retried line doubled.
--
--   admission_intake_sessions(provider_session_key)
--       Session identity. Two rows for one WhatsApp conversation splits
--       a parent's messages across two sessions, and each gets extracted
--       separately — two admissions for one child.
--
--   admission_intake_sessions(display_id)
--       The AgentAlpha reference the manager reads back to a parent.
--
--   admission_payment_claims(session_id)
--   admission_payment_claims(student_payment_id) where not null
--       ONE PAYMENT PER CLAIM. verify_admission_payment_claim (ported
--       hours ago in 2026-08-12k) guards with
--           if v_claim.student_payment_id is not null then return
--       which is a check-then-act. It is only safe if something stops
--       two concurrent runs both passing the check. That something is
--       this index. Without it, two taps take the money twice.
--
--   admissions(intake_session_id) where not null
--       One admission per intake conversation.
--
--   admissions(reg_no)
--       Two children cannot share a registration number.
--
-- WHY NOTHING IS BROKEN YET. Checked before creating: zero duplicate
-- values across all seven. The AgentAlpha sweep has been off since the
-- cutover, so almost nothing exercised these paths — and 2026-08-12j
-- turned it back on today. This is the second defect in a row that was
-- harmless only because the scheduler was stopped.
--
-- The non-unique indexes below are ordinary performance ones, restored
-- in the same pass. They are cheap on tables this size and they match
-- the queries the function actually issues — notably (status,
-- last_message_at) and (session_id, message_timestamp), which are the
-- debounce sweep and the conversation replay.
-- ============================================================

-- ------------------------------------------------------------
-- The seven that guarantee uniqueness
-- ------------------------------------------------------------
create unique index if not exists admission_intake_messages_provider_message_id_key
  on genalpha.admission_intake_messages (provider_message_id);

create unique index if not exists admission_intake_sessions_provider_session_key_key
  on genalpha.admission_intake_sessions (provider_session_key);

create unique index if not exists admission_intake_sessions_display_id_key
  on genalpha.admission_intake_sessions (display_id);

create unique index if not exists admission_payment_claims_session_id_key
  on genalpha.admission_payment_claims (session_id);

create unique index if not exists admission_payment_claims_student_payment_id_key
  on genalpha.admission_payment_claims (student_payment_id)
  where student_payment_id is not null;

create unique index if not exists admissions_intake_session_id_key
  on genalpha.admissions (intake_session_id)
  where intake_session_id is not null;

create unique index if not exists admissions_reg_no_key
  on genalpha.admissions (reg_no);

-- ------------------------------------------------------------
-- The query indexes, matching what the function asks for
-- ------------------------------------------------------------
create index if not exists admission_intake_sessions_status_last_message_idx
  on genalpha.admission_intake_sessions (status, last_message_at desc);

create index if not exists admission_intake_sessions_chat_sender_idx
  on genalpha.admission_intake_sessions (source_chat_id, source_sender_id, last_message_at desc);

create index if not exists admission_intake_messages_session_ts_idx
  on genalpha.admission_intake_messages (session_id, message_timestamp);

create index if not exists admission_intake_messages_chat_ts_idx
  on genalpha.admission_intake_messages (source_chat_id, message_timestamp)
  where session_id is null;

create index if not exists payment_link_requests_student_created_idx
  on genalpha.payment_link_requests (student_id, created_at desc);

create index if not exists whatsapp_webhook_events_created_idx
  on genalpha.whatsapp_webhook_events (created_at desc);

create index if not exists whatsapp_webhook_events_from_created_idx
  on genalpha.whatsapp_webhook_events (from_phone, created_at desc);

-- The debounce sweep filters on updated_at, which 2026-08-12l only just
-- started maintaining. It had no index on legacy either, because there
-- the same query was served by (status, last_message_at). Added because
-- the sweep runs every 10 seconds now.
create index if not exists admission_intake_sessions_status_updated_idx
  on genalpha.admission_intake_sessions (status, updated_at);

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v_id uuid; v_key text;
begin
  select count(*) into n from pg_indexes
   where schemaname='genalpha' and indexname in (
     'admission_intake_messages_provider_message_id_key',
     'admission_intake_sessions_provider_session_key_key',
     'admission_intake_sessions_display_id_key',
     'admission_payment_claims_session_id_key',
     'admission_payment_claims_student_payment_id_key',
     'admissions_intake_session_id_key',
     'admissions_reg_no_key');
  if n <> 7 then raise exception 'only % of the 7 unique indexes exist', n; end if;

  -- Prove the dedup key REJECTS, rather than trusting that it exists.
  -- This is the whole reason the file was written.
  select provider_message_id into v_key from genalpha.admission_intake_messages
   where provider_message_id is not null limit 1;
  if v_key is not null then
    begin
      insert into genalpha.admission_intake_messages (id, provider_message_id, message_type)
      values (gen_random_uuid(), v_key, 'text');
      raise exception 'a duplicate provider_message_id was accepted — Meta''s retries will double every message';
    exception
      when unique_violation then
        raise notice 'the WhatsApp dedup key rejects duplicates again';
      when others then
        if sqlerrm like '%duplicate%' then
          raise notice 'the WhatsApp dedup key rejects duplicates again';
        else raise; end if;
    end;
  end if;

  -- and the money one: two claims cannot point at the same payment.
  -- Probed by UPDATE rather than INSERT — a new claim row would trip
  -- session_id NOT NULL before it ever reached the index under test.
  declare v_a uuid; v_b uuid; v_pay uuid;
  begin
    select id, student_payment_id into v_a, v_pay
      from genalpha.admission_payment_claims
     where student_payment_id is not null limit 1;
    select id into v_b from genalpha.admission_payment_claims
     where student_payment_id is null and id <> coalesce(v_a, id) limit 1;

    if v_a is null or v_b is null then
      raise notice 'not enough claims to collide; the unique index exists but was not exercised';
    else
      begin
        update genalpha.admission_payment_claims
           set student_payment_id = v_pay where id = v_b;
        raise exception 'two claims now share payment % — verify_admission_payment_claim can double-charge', v_pay;
      exception when unique_violation then
        raise notice 'one payment per claim is enforced again';
      end;
    end if;
  end;

  select count(*) into n from pg_indexes where schemaname='genalpha';
  raise notice 'genalpha now carries % indexes', n;
end $$;
