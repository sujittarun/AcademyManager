-- ============================================================
-- 2026-08-11x · The secret writers refuse the one caller who has no JWT
-- scope: shared
--
--   select set_whatsapp_secret('genalpha', '<token>');
--   ERROR:  42501: not authorised
--
-- The guard on all three secret writers is:
--
--   auth_role() = 'operator'
--     or (auth_role() = 'staff' and auth_tenant() = p_tenant)
--
-- In the Supabase SQL editor there is no JWT at all: current_user is
-- postgres and auth_role() returns null, so neither branch is true. The
-- functions are reachable by every role that should NOT be storing a
-- token and unreachable by the one person who actually has it.
--
-- is_service() already models exactly this. It is true when there are no
-- JWT claims (the SQL editor, the migration runner, a cron job) or when
-- the claim says service_role, and it is what assert_staff_or_service()
-- is built on. The other definer functions on this platform accept it;
-- these three were written without it.
--
-- This is a widening, so it is worth being exact about what it lets in.
-- is_service() is true only where there is no browser: a JWT-less
-- connection is one that already holds the database password or the
-- service key, and anyone in that position can write vault.secrets
-- directly. It grants nothing that was not already reachable — it just
-- stops the supported path being the broken one.
--
-- What does NOT change: nothing gains the ability to READ a token.
-- whatsapp_credentials() stays service_role-only, and vault.secrets and
-- vault.decrypted_secrets remain unreadable by anon and authenticated.
-- ============================================================

do $$
declare
  f    record;
  src  text;
  new_src text;
  n    int := 0;
begin
  for f in
    select p.oid, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('set_whatsapp_secret', 'set_integration_secret', 'connect_integration')
  loop
    src := pg_get_functiondef(f.oid);

    if src ~* 'is_service\(\)' then
      raise notice '% already accepts is_service()', f.proname;
      continue;
    end if;

    -- Insert the service branch into the existing guard rather than
    -- rewriting the body. Each of these functions does different work
    -- after the check, and retyping three bodies to change one line is
    -- how a subtle difference gets lost.
    new_src := replace(
      src,
      'auth_role() = ''operator''',
      'is_service() or auth_role() = ''operator''');

    if new_src = src then
      raise exception 'could not find the guard in % — refusing to guess', f.proname;
    end if;

    execute new_src;
    n := n + 1;
    raise notice 'widened %', f.proname;
  end loop;

  if n = 0 then
    raise notice 'nothing to change';
  end if;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; r jsonb;
begin
  -- All three must now admit the service path.
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('set_whatsapp_secret','set_integration_secret','connect_integration')
     and pg_get_functiondef(p.oid) ~* 'is_service\(\)';
  if n <> 3 then raise exception 'only % of 3 secret writers accept is_service()', n; end if;

  -- ...and must still reject a caller who is neither service nor staff.
  -- This is the half that matters: a widening that also opened the door
  -- to anon would pass a "does it work now" check perfectly.
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('set_whatsapp_secret','set_integration_secret','connect_integration')
     and has_function_privilege('anon', p.oid, 'execute');
  if n <> 0 then raise exception '% secret writer(s) are anon-executable', n; end if;

  -- Nothing gained READ access to a token.
  if has_function_privilege('authenticated', 'whatsapp_credentials(text)'::regprocedure, 'execute')
     or has_function_privilege('anon', 'whatsapp_credentials(text)'::regprocedure, 'execute') then
    raise exception 'whatsapp_credentials() became readable outside service_role';
  end if;
  if has_table_privilege('authenticated', 'vault.decrypted_secrets', 'select')
     or has_table_privilege('anon', 'vault.decrypted_secrets', 'select') then
    raise exception 'the vault became readable from a browser role';
  end if;

  -- Prove the real call works end to end, then undo it. Reading the
  -- source would not have caught the original bug either — auth_role()
  -- returning null is a runtime fact, not a visible one.
  r := set_whatsapp_secret('genalpha', 'PLACEHOLDER-not-a-real-token-0123456789');
  if not (r->>'ok')::boolean then
    raise exception 'set_whatsapp_secret still refuses the service path: %', r::text;
  end if;
  if (select count(*) from vault.secrets where name = 'whatsapp:genalpha') <> 1 then
    raise exception 'the secret was not written';
  end if;

  -- and it must be scoped to the tenant it was called for
  if exists (select 1 from vault.secrets
              where name like 'whatsapp:%' and name <> 'whatsapp:genalpha') then
    raise exception 'a token landed under another tenant''s name';
  end if;

  -- Remove the placeholder. The real token is set by a human, once, and
  -- a migration must never leave a working-looking credential behind.
  delete from vault.secrets where name = 'whatsapp:genalpha';
  update tenants
     set config = jsonb_set(config, '{whatsapp,hasOwnToken}', 'false'::jsonb, true)
   where id = 'genalpha';

  if (select has_own_token from whatsapp_senders() where tenant_id = 'genalpha') then
    raise exception 'genalpha still reads as having a token after cleanup';
  end if;

  raise notice 'all three secret writers accept the service path; placeholder written, verified and removed';
end $$;
