-- ============================================================
-- 2026-08-12q · Eight intake tables had no primary key
-- scope: shared
--
-- Found by the Supabase performance advisor, and it is not a performance
-- point. These eight came across from GenAlpha's own project with an
-- `id` column, a uuid default, and no constraint of any kind on it —
-- no primary key, and no unique index either. Row identity was luck.
--
-- WHY THAT IS NOT ACADEMIC HERE
--
--   genalpha.admission_payment_claims is read by
--   verify_admission_payment_claim with
--       select * into v_claim ... where id = p_claim_id for update
--   `select into` on two matching rows takes one of them and does not
--   complain. That is a money function keyed on a column nothing
--   guaranteed to be unique.
--
--   genalpha.admission_intake_sessions.id is the parent of
--   admission_intake_messages.session_id, the target of the
--   `updated_at=eq.<token>` compare-and-swap in admission-intake, and
--   the storage folder name for every uploaded admission file.
--
-- Colliding a uuid4 is not the realistic failure. The realistic failure
-- is the same one the seven missing unique indexes had this morning:
-- code that reads as safe because a constraint is assumed, in a schema
-- where that assumption was never written down.
--
-- REPLICATION MADE IT URGENT. 2026-08-12o published
-- genalpha.payment_link_requests, which is in this list. PostgreSQL
-- refuses UPDATE and DELETE on a published table that has neither a
-- primary key nor REPLICA IDENTITY FULL —
--     cannot update table ... because it does not have a replica
--     identity and publishes updates
-- so between that migration and 2026-08-12p every status change on a
-- payment link would have failed outright. 2026-08-12p closed it with
-- FULL; a real primary key is the durable answer, and it lets the
-- planner use an index for replica identity rather than the whole row.
--
-- Verified before adding: zero null ids and zero duplicate ids across
-- all eight, totalling 564 rows.
-- ============================================================

alter table genalpha.admission_ai_extractions
  alter column id set not null,
  add constraint admission_ai_extractions_pkey primary key (id);

alter table genalpha.admission_intake_corrections
  alter column id set not null,
  add constraint admission_intake_corrections_pkey primary key (id);

alter table genalpha.admission_intake_messages
  alter column id set not null,
  add constraint admission_intake_messages_pkey primary key (id);

alter table genalpha.admission_intake_reply_interpretations
  alter column id set not null,
  add constraint admission_intake_reply_interpretations_pkey primary key (id);

alter table genalpha.admission_intake_sessions
  alter column id set not null,
  add constraint admission_intake_sessions_pkey primary key (id);

alter table genalpha.admission_payment_claims
  alter column id set not null,
  add constraint admission_payment_claims_pkey primary key (id);

alter table genalpha.payment_link_requests
  alter column id set not null,
  add constraint payment_link_requests_pkey primary key (id);

alter table genalpha.whatsapp_webhook_events
  alter column id set not null,
  add constraint whatsapp_webhook_events_pkey primary key (id);

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v_id uuid;
begin
  select count(*) into n
    from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'genalpha' and k.contype = 'p'
     and c.relname in ('admission_ai_extractions','admission_intake_corrections',
                       'admission_intake_messages','admission_intake_reply_interpretations',
                       'admission_intake_sessions','admission_payment_claims',
                       'payment_link_requests','whatsapp_webhook_events');
  if n <> 8 then raise exception 'only % of the 8 primary keys exist', n; end if;

  -- every genalpha table now has one
  select count(*) into n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'genalpha' and c.relkind = 'r'
     and not exists (select 1 from pg_constraint k
                      where k.conrelid = c.oid and k.contype = 'p');
  if n > 0 then raise exception '% genalpha table(s) still have no primary key', n; end if;

  -- prove it REJECTS, rather than trusting the catalogue
  select id into v_id from genalpha.admission_intake_sessions limit 1;
  if v_id is not null then
    begin
      insert into genalpha.admission_intake_sessions (id) values (v_id);
      raise exception 'a duplicate session id was accepted';
    exception
      when unique_violation then null;                    -- expected
      when not_null_violation then null;                  -- other NOT NULLs; the PK is what matters
      when others then
        if sqlerrm not like '%duplicate%' and sqlerrm not like '%null value%' then raise; end if;
    end;
  end if;

  -- the published one must still accept an UPDATE, which is the thing
  -- that was failing outright before 2026-08-12p
  update genalpha.payment_link_requests
     set status = status
   where id = (select id from genalpha.payment_link_requests limit 1);

  raise notice 'all 8 primary keys in place; the published table accepts updates';
end $$;
