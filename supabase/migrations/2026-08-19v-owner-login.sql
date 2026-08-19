-- ============================================================
-- 2026-08-19v · academymanager@outlook.in becomes the owner's one login
-- scope: shared
--
-- One account, every academy. `2026-08-19u` already gave the operator
-- role write access to all 32 tenant tables, and reads and RPCs worked
-- before that — so all this file does is put the claim on the account.
--
-- IT DOES NOT CREATE THE ACCOUNT. Creating a login and setting a
-- password is done by hand in the Supabase dashboard, deliberately: a
-- password should never pass through a migration file, a chat, or git.
-- Create it first, then apply this.
--
-- APP METADATA, NOT USER METADATA. A user can edit their own user
-- metadata, which is exactly why RLS reads `app_metadata`. Putting
-- am_role in the wrong one produces an account that signs in perfectly
-- and then sees nothing at all — indistinguishable from a broken app,
-- and the single most common way an onboarding goes wrong here.
--
-- `operator@academymanager.in` KEEPS its role. Two operator logins is
-- deliberate: if the new one is ever locked out or its password has to
-- be rotated, the console is still reachable. Retire the old one on
-- purpose, not as a side effect of this file.
-- ============================================================

do $$
declare v_id uuid; v_role text; v_tenant text;
begin
  select id, raw_app_meta_data->>'am_role', raw_app_meta_data->>'tenant_id'
    into v_id, v_role, v_tenant
    from auth.users where lower(email) = 'academymanager@outlook.in';

  if v_id is null then
    raise exception
      'academymanager@outlook.in does not exist yet. Create it in the Supabase '
      'dashboard (Authentication -> Users -> Add user, confirm the email), then '
      're-apply this file. Passwords are set there, never here.';
  end if;

  -- A tenant_id on an operator is meaningless at best: every policy that
  -- matters reads am_role, and a stray tenant_id invites someone later to
  -- believe this account is scoped when it is not. Say operator, only.
  update auth.users
     set raw_app_meta_data =
           coalesce(raw_app_meta_data, '{}'::jsonb)
           || jsonb_build_object('am_role', 'operator')
           - 'tenant_id'
   where id = v_id;

  raise notice 'academymanager@outlook.in: am_role was %, tenant was % -> operator, no tenant',
    coalesce(v_role,'(none)'), coalesce(v_tenant,'(none)');
end $$;

-- ------------------------------------------------------------
-- Checks — this account can now reach every academy, so prove it
-- reaches them and prove nobody else gained anything.
-- ------------------------------------------------------------
do $chk$
declare v_id uuid; n int; t text; total int; seen int;
begin
  select id into v_id from auth.users where lower(email) = 'academymanager@outlook.in';

  if (select raw_app_meta_data->>'am_role' from auth.users where id = v_id) <> 'operator' then
    raise exception 'the claim did not stick';
  end if;
  if (select raw_app_meta_data ? 'tenant_id' from auth.users where id = v_id) then
    raise exception 'the account still carries a tenant_id, which would mislead the next reader';
  end if;

  -- Sign in AS this account's claims and read every academy, one by one.
  -- Counting the total in one query would pass even if a single tenant
  -- were invisible, which is the reading that matters for a demo.
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', v_id::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  for t in select id from tenants order by id loop
    select count(*) into total from members m where m.tenant_id = t;
    set local role authenticated;
    execute format('select count(*) from members where tenant_id = %L', t) into seen;
    reset role;
    if seen <> total then
      raise exception 'the owner sees % of %s % members', seen, total, t;
    end if;
  end loop;

  -- and can write into one of them, cleaning up after itself
  set local role authenticated;
  insert into members (tenant_id, name, status, joined)
  values ('leo', 'ZZ Owner Probe', 'active', current_date);
  reset role;
  delete from members where tenant_id = 'leo' and name = 'ZZ Owner Probe';
  if exists (select 1 from members where name = 'ZZ Owner Probe') then
    raise exception 'the probe row was left behind';
  end if;
  perform set_config('request.jwt.claims', null, true);

  -- nobody else became an operator along the way
  select count(*) into n from auth.users
   where raw_app_meta_data->>'am_role' = 'operator';
  if n > 2 then
    raise exception '% operator accounts exist; expected the old one and the new one', n;
  end if;

  raise notice 'academymanager@outlook.in reads and writes every academy';
end $chk$;
