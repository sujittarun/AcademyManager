-- ============================================================
-- 2026-08-05 · Each academy sends from its OWN WhatsApp number
-- scope: shared
--
-- Until now one number sent for every academy: the edge function read
-- META_WHATSAPP_PHONE_NUMBER_ID from its environment, so every reminder
-- for Leo, Machaxi, Raj and MPP left from +91 82977 71212 ("Academy
-- Manager") and the academy's own name appeared only as template
-- variable {{2}}. A parent therefore saw a message from us about their
-- academy, rather than from their academy.
--
-- Three things follow from one shared sender, and all three are why
-- this changes:
--   · the sender name on the parent's phone is ours, not the client's;
--   · Meta's messaging tier (TIER_250 today) is a property of the NUMBER,
--     so every academy competes for the same 250 recipients a day;
--   · quality rating is per number too — one academy's spam reports
--     degrade deliverability for all of them.
--
-- What this migration adds is the RESOLUTION layer: a way for the send
-- path to ask "which number, and with which token, does THIS tenant
-- send from?" and to get a per-tenant answer.
--
-- Design notes worth keeping:
--
-- 1. The phone number id and WABA id are identifiers, not secrets, so
--    they live in tenants.config.whatsapp where the tenant's own staff
--    can see them. The ACCESS TOKEN is a secret and must not go there —
--    tenants.config is readable by that tenant's staff, so a token in it
--    is a token handed to the customer. It goes in Vault, exactly like
--    partner:<tenant>:<channel> does for Playo/Hudle (schema.sql:1156).
--
-- 2. The token is OPTIONAL per tenant. In the normal setup every client
--    number is onboarded into one Meta Business Manager under a single
--    System User, and that one token can send from all of them — so only
--    the phone number id differs per tenant. A per-tenant token is there
--    for the case where an academy brings its own Meta Business.
--
-- 3. Fail closed. A tenant with no phoneNumberId configured must NOT
--    silently fall back to the platform number — that is precisely the
--    behaviour being removed, and a silent fallback would mean a client
--    who thinks they are sending as themselves is still sending as us.
--    The function refuses instead; this migration only supplies the data.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Store an academy's own Meta token, encrypted.
--    Mirrors set_integration_secret: the operator may set any tenant's,
--    a tenant's staff may set their own, nobody else may set anything.
-- ------------------------------------------------------------
create or replace function public.set_whatsapp_secret(p_tenant text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_name text; v_id uuid; v_existing uuid;
begin
  if not (auth_role() = 'operator'
          or (auth_role() = 'staff' and auth_tenant() = p_tenant)) then
    raise exception 'not authorised' using errcode = '42501';
  end if;
  if not tenant_exists(p_tenant) then
    raise exception 'unknown tenant %', p_tenant;
  end if;
  if coalesce(length(trim(p_token)), 0) < 20 then
    raise exception 'that does not look like a Meta access token';
  end if;

  v_name := 'whatsapp:' || p_tenant;
  select id into v_existing from vault.secrets where name = v_name;
  if v_existing is not null then
    perform vault.update_secret(v_existing, p_token);
    v_id := v_existing;
  else
    v_id := vault.create_secret(p_token, v_name,
              'Meta WhatsApp access token for ' || p_tenant);
  end if;

  -- record only that a token exists, never the token itself
  update tenants
     set config = jsonb_set(coalesce(config, '{}'::jsonb), '{whatsapp,hasOwnToken}',
                            'true'::jsonb, true)
   where id = p_tenant;

  return jsonb_build_object('ok', true, 'stored', 'encrypted in Vault', 'secret', v_name);
end $$;

comment on function public.set_whatsapp_secret(text, text) is
  'Stores an academy''s own Meta WhatsApp token in Vault. Operator, or that tenant''s own staff. The token is never written to tenants.config.';
revoke execute on function public.set_whatsapp_secret(text, text) from public, anon;
grant execute on function public.set_whatsapp_secret(text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- 2. Hand the send path the credentials for ONE tenant.
--    service_role only: this returns a live token, so it must never be
--    reachable by a signed-in staff member, let alone anon. The edge
--    function calls it with the service key it already holds.
-- ------------------------------------------------------------
create or replace function public.whatsapp_credentials(p_tenant text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_cfg jsonb; v_token text;
begin
  -- No auth_role() branch on purpose: the grant IS the guard. Only
  -- service_role can execute this, and service_role is never in a
  -- browser (PLATFORM.md). A staff-readable version of this would be a
  -- token-exfiltration endpoint.
  select coalesce(config->'whatsapp', '{}'::jsonb) into v_cfg
    from tenants where id = p_tenant;
  if v_cfg is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown tenant');
  end if;

  select decrypted_secret into v_token
    from vault.decrypted_secrets where name = 'whatsapp:' || p_tenant;

  return jsonb_build_object(
    'ok', true,
    'phoneNumberId', nullif(v_cfg->>'phoneNumberId', ''),
    'wabaId',        nullif(v_cfg->>'wabaId', ''),
    -- null means "use the platform System User token", which is correct
    -- when the client's number sits in our Business Manager
    'token',         v_token,
    'hasOwnToken',   v_token is not null
  );
end $$;

comment on function public.whatsapp_credentials(text) is
  'The number and token ONE tenant sends from. service_role only — it returns a live Meta token.';
revoke execute on function public.whatsapp_credentials(text) from public, anon, authenticated;
grant execute on function public.whatsapp_credentials(text) to service_role;

-- ------------------------------------------------------------
-- 3. Operator view: who is set up to send as themselves, and who is not.
--    Never returns a token — only whether one exists.
-- ------------------------------------------------------------
create or replace function public.whatsapp_senders()
returns table (tenant_id text, academy text, phone_number_id text, waba_id text,
               has_own_token boolean, enabled boolean, mode text, ready boolean)
language sql
stable
security definer
set search_path = public
as $$
  select t.id,
         t.name,
         nullif(t.config#>>'{whatsapp,phoneNumberId}', ''),
         nullif(t.config#>>'{whatsapp,wabaId}', ''),
         exists (select 1 from vault.secrets v where v.name = 'whatsapp:' || t.id),
         coalesce((t.config#>>'{whatsapp,enabled}')::boolean, false),
         coalesce(t.config#>>'{whatsapp,mode}', 'manual'),
         nullif(t.config#>>'{whatsapp,phoneNumberId}', '') is not null
    from tenants t
   order by t.id
$$;
comment on function public.whatsapp_senders() is
  'Per-academy WhatsApp sender readiness for the operator console. Reports whether a token exists, never what it is.';
revoke execute on function public.whatsapp_senders() from public, anon;
grant execute on function public.whatsapp_senders() to authenticated, service_role;

-- ------------------------------------------------------------
-- 4. Record the number the platform already owns against the tenant that
--    is actually using it, so nothing regresses on deploy.
--    mpp already carries this id; raj has none and will fail closed
--    until it is given one, which is the intended new behaviour.
-- ------------------------------------------------------------
do $$
begin
  update tenants
     set config = jsonb_set(coalesce(config, '{}'::jsonb), '{whatsapp,phoneNumberId}',
                            '"1274588119067440"'::jsonb, true)
   where id = 'mpp'
     and coalesce(config#>>'{whatsapp,phoneNumberId}', '') = '';
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v jsonb; v_n int;
begin
  -- the resolver answers, and does not leak a token when none is stored
  v := whatsapp_credentials('mpp');
  if (v->>'ok')::boolean is not true then raise exception 'resolver failed for mpp'; end if;
  if v->>'phoneNumberId' is null then raise exception 'mpp has no phoneNumberId after backfill'; end if;

  -- raj is deliberately not ready: it must fail closed rather than borrow the platform number
  v := whatsapp_credentials('raj');
  if v->>'phoneNumberId' is not null then
    raise exception 'raj unexpectedly has a phoneNumberId — check the backfill';
  end if;

  -- the operator view lists every tenant and marks readiness
  select count(*) into v_n from whatsapp_senders();
  if v_n = 0 then raise exception 'whatsapp_senders() returned nothing'; end if;

  -- A signed-in staff member must not be able to read credentials, because
  -- this function returns a live Meta token.
  --
  -- The guard here is the GRANT, not auth_role(), so the test has to
  -- actually become the role. Setting request.jwt.claims alone proves
  -- nothing: the migration runs as postgres, which bypasses grants and
  -- would have reported a pass. (Same lesson as anon_probe — a shape
  -- check cannot see behaviour.)
  set local role authenticated;
  begin
    perform whatsapp_credentials('raj');
    reset role;
    raise exception 'authenticated could read whatsapp_credentials — that returns a live token';
  exception
    when insufficient_privilege then null;   -- what we want
  end;
  reset role;

  raise notice 'per-tenant WhatsApp credentials in place; % tenants listed', v_n;
end $$;
