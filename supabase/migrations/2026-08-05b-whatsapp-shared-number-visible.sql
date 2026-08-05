-- ============================================================
-- 2026-08-05b · "Ready" must not mean "still sending as us"
-- scope: shared
--
-- 2026-08-05-per-tenant-whatsapp-number.sql made the send path resolve a
-- number per tenant, and backfilled mpp with 1274588119067440 so nothing
-- regressed on deploy. Probing that id afterwards returned:
--
--     display_phone_number : +91 82977 71212
--     verified_name        : AcademyManager
--
-- That is the PLATFORM's number. So mpp reads ready = true in
-- whatsapp_senders() while a parent still sees a message from us — the
-- exact confusion this work exists to remove, now wearing a green tick.
--
-- The mechanism is correct and the backfill was right: mpp was the only
-- tenant actually sending, and removing its number would have stopped
-- live reminders to prove a point. What was wrong is the REPORT. A
-- readiness view that cannot tell "has a number" from "has its OWN
-- number" will let the shared sender survive indefinitely, because
-- nothing will ever look wrong.
--
-- So: name the platform number, and split readiness in two.
--
-- The id is safe to write down. A phone_number_id is an identifier, not
-- a credential — the same reasoning that already puts phoneNumberId and
-- wabaId in tenants.config while the access token goes to Vault. It
-- appears in the Meta dashboard and in every Graph URL. Knowing it grants
-- nothing without the token.
-- ============================================================

create or replace function public.whatsapp_platform_number()
returns text
language sql
immutable
as $$
  -- +91 82977 71212, "AcademyManager". The number every tenant shared
  -- before per-tenant sending existed. Kept as a function rather than a
  -- literal in three places so there is one thing to change on the day
  -- the platform number itself changes.
  select '1274588119067440'
$$;
comment on function public.whatsapp_platform_number() is
  'The platform''s own WhatsApp phone_number_id. An identifier, not a secret — the token is the secret.';

-- ------------------------------------------------------------
-- Readiness, honestly. Three states, not two:
--   own_number  — configured, and it is not ours          → the goal
--   shared      — configured, but it IS ours              → works, wrong sender
--   none        — nothing configured                      → fails closed
-- ------------------------------------------------------------
drop function if exists public.whatsapp_senders();
create function public.whatsapp_senders()
returns table (tenant_id text, academy text, phone_number_id text, waba_id text,
               has_own_token boolean, enabled boolean, mode text,
               sender text, sends_as_self boolean, ready boolean)
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
         case
           when nullif(t.config#>>'{whatsapp,phoneNumberId}', '') is null then 'none'
           when t.config#>>'{whatsapp,phoneNumberId}' = whatsapp_platform_number()
             then 'shared'
           else 'own_number'
         end,
         -- the number on the parent's phone is the academy's, not ours
         coalesce(nullif(t.config#>>'{whatsapp,phoneNumberId}', '')
                    <> whatsapp_platform_number(), false),
         -- can send at all. Deliberately still true for 'shared': it is a
         -- working configuration, just not the one we are aiming at.
         nullif(t.config#>>'{whatsapp,phoneNumberId}', '') is not null
    from tenants t
   order by t.id
$$;
comment on function public.whatsapp_senders() is
  'Per-academy WhatsApp sender readiness. sender is none | shared | own_number; sends_as_self is false while an academy is still on the platform number. Reports whether a token exists, never what it is.';
revoke execute on function public.whatsapp_senders() from public, anon;
grant execute on function public.whatsapp_senders() to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v_shared int; v_own int; v_none int; v_mpp record;
begin
  select count(*) filter (where sender = 'shared'),
         count(*) filter (where sender = 'own_number'),
         count(*) filter (where sender = 'none')
    into v_shared, v_own, v_none
    from whatsapp_senders();

  -- mpp is the one tenant with a number, and today it is ours
  select * into v_mpp from whatsapp_senders() where tenant_id = 'mpp';
  if v_mpp.sender <> 'shared' then
    raise exception 'expected mpp on the shared platform number, got %', v_mpp.sender;
  end if;
  if v_mpp.sends_as_self then
    raise exception 'mpp reported as sending as itself while on the platform number';
  end if;
  if not v_mpp.ready then
    raise exception 'mpp lost readiness — it can still send, the sender is just ours';
  end if;

  -- a tenant with nothing configured must not read as sending as itself
  if exists (select 1 from whatsapp_senders() where sender = 'none' and sends_as_self) then
    raise exception 'a tenant with no number reported sends_as_self';
  end if;

  raise notice 'whatsapp senders: % own, % shared, % unconfigured', v_own, v_shared, v_none;
end $$;
