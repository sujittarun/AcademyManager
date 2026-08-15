-- ============================================================
-- 2026-08-15a · AgentAlpha ingest: the messages→sessions relationship
-- scope: shared
--
-- Every AgentAlpha ingest has been failing since the cutover with:
--
--   "Could not find a relationship between 'admission_intake_messages'
--    and 'admission_intake_sessions' in the schema cache"
--
-- ingestMessage()'s first query embeds the parent session:
--   admission_intake_messages?select=*,admission_intake_sessions(*)
-- and PostgREST can only resolve an embed through a real FOREIGN KEY.
-- 2026-08-11n created the table with a bare `session_id uuid` and no
-- constraint; 2026-08-12q then added PRIMARY KEYs to both tables — its own
-- comment names sessions.id as "the parent of messages.session_id" — but
-- never added the FK itself. So the parent link PostgREST needs has never
-- existed in this project.
--
-- Effect: staff send a form or a payment screenshot, genalpha-whatsapp
-- forwards it, the ingest 400s, the forwarder swallows the error and the
-- message is dropped. Nothing is written and nothing is answered, which is
-- exactly what "nothing happened" looked like.
--
-- Added NOT VALID: new and updated rows are enforced immediately (which is
-- all the ingest needs), while any legacy orphan row from the migration is
-- left alone rather than failing the deploy. The DO block below reports
-- whether a full validation is possible and validates when it is.
-- ============================================================

alter table genalpha.admission_intake_messages
  drop constraint if exists admission_intake_messages_session_id_fkey;

alter table genalpha.admission_intake_messages
  add constraint admission_intake_messages_session_id_fkey
  foreign key (session_id) references genalpha.admission_intake_sessions (id)
  on delete cascade
  not valid;

do $$
declare
  v_orphans bigint;
begin
  select count(*) into v_orphans
    from genalpha.admission_intake_messages m
   where m.session_id is not null
     and not exists (
       select 1 from genalpha.admission_intake_sessions s where s.id = m.session_id
     );

  if v_orphans = 0 then
    alter table genalpha.admission_intake_messages
      validate constraint admission_intake_messages_session_id_fkey;
    raise notice 'no orphan intake messages; constraint validated';
  else
    raise notice '% orphan intake message(s) predate the constraint; left NOT VALID', v_orphans;
  end if;
end $$;

-- PostgREST caches the relationship graph; without this the embed keeps
-- failing until the next unrelated schema change happens to reload it.
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
      from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname = 'genalpha'
       and t.relname = 'admission_intake_messages'
       and c.contype = 'f'
       and c.conname = 'admission_intake_messages_session_id_fkey'
  ) then
    raise exception 'the messages->sessions foreign key is missing; PostgREST still cannot embed';
  end if;
  raise notice 'messages->sessions foreign key present';
end $$;
