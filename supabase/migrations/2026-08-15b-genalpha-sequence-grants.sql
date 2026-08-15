-- ============================================================
-- 2026-08-15b · genalpha sequences were never granted
-- scope: shared
--
-- AgentAlpha drops every image. Reproduced against production:
--
--   POST admission-intake {action:ingest, message_type:"image"}
--   -> 400 {"error":"permission denied for sequence admission_intake_display_seq"}
--
-- genalpha.admission_intake_sessions.display_id defaults to
-- nextval('genalpha.admission_intake_display_seq'), so inserting a session
-- needs USAGE on that sequence. The cutover granted USAGE on the *schema*
-- (2026-08-11a) and revoked sequences from anon (2026-08-11h), but never
-- granted sequences to authenticated or service_role. A default that calls
-- nextval then fails for whoever inserts.
--
-- Staff send a screenshot, genalpha-whatsapp forwards it, the standalone
-- media session cannot be created, the forwarder swallows the error, and
-- the image never reaches the model — which is why AgentAlpha answered
-- about a payment it could not see.
--
-- Grants every existing sequence in the schema and sets the default for
-- ones added later, so the next table with a sequence-backed default does
-- not rediscover this the same way. anon stays revoked, as 2026-08-11h
-- intended.
-- ============================================================

grant usage, select on all sequences in schema genalpha to authenticated, service_role;

alter default privileges in schema genalpha
  grant usage, select on sequences to authenticated, service_role;

-- 2026-08-11h deliberately keeps anon away from these; re-assert it so the
-- blanket grant above cannot widen the public surface.
revoke all on all sequences in schema genalpha from anon;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  r        record;
  v_missing text := '';
  v_anon    text := '';
begin
  -- A loop, not a set-returning query: Postgres is free to evaluate
  -- has_sequence_privilege() before the relkind filter, and it then trips over
  -- the first non-sequence relation it sees.
  for r in
    select c.oid, c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'genalpha' and c.relkind = 'S'
  loop
    if not has_sequence_privilege('authenticated', r.oid, 'USAGE') then
      v_missing := v_missing || r.relname || ' ';
    end if;
    if has_sequence_privilege('anon', r.oid, 'USAGE') then
      v_anon := v_anon || r.relname || ' ';
    end if;
  end loop;

  if v_missing <> '' then
    raise exception 'authenticated still cannot use sequence(s): %', v_missing;
  end if;
  if v_anon <> '' then
    raise exception 'anon can use sequence(s) it must not: %', v_anon;
  end if;

  -- The one that actually broke AgentAlpha.
  if not has_sequence_privilege('service_role', 'genalpha.admission_intake_display_seq'::regclass, 'USAGE') then
    raise exception 'service_role still cannot use admission_intake_display_seq';
  end if;

  raise notice 'genalpha sequences granted to authenticated and service_role; anon excluded';
end $$;
