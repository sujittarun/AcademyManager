-- ============================================================
-- 2026-08-11r · GenAlpha's own WhatsApp number
-- scope: shared
--
-- 8143960950, the number GenAlpha's families already recognise. Its
-- phone_number_id and waba_id came from the owner's Meta account.
--
-- The token does NOT go here. Config is readable by anyone who can read
-- the tenant row; the token lives in vault.secrets via
-- set_whatsapp_secret(), which is why whatsapp_senders() reports
-- has_own_token separately from these two ids.
--
-- enabled stays FALSE and mode stays 'manual' on purpose. Turning a real
-- number on is a decision about messaging 81 real families, and it should
-- be made by a person looking at the reminder queue, not fall out of a
-- migration. Flipping it is a one-line update once the token is set and
-- whatsapp_senders() reports sender='own_number'.
-- ============================================================

update tenants
   set config = jsonb_set(
         coalesce(config, '{}'::jsonb),
         '{whatsapp}',
         coalesce(config->'whatsapp', '{}'::jsonb) || jsonb_build_object(
           'phoneNumberId', '1131427080050707',
           'wabaId',        '896291036765497',
           'managerPhone',  '918143960950',
           'enabled',       false,
           'mode',          'manual',
           'dryRun',        true,
           'sendHourIST',   15,
           'templates',     jsonb_build_object(
             'headsUp',  'utlity_fee_headsup',
             'dueToday', 'utility_renewal_day',
             'overdue',  'utility_for_fee_reminder'
           )
         ),
         true)
 where id = 'genalpha';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare r record;
begin
  -- jsonb_set with create_missing only creates the FINAL key, and
  -- genalpha's config had no whatsapp object at all. That exact hazard
  -- took Raj's timetable down in 0004, so assert rather than assume.
  select * into r from whatsapp_senders() where tenant_id = 'genalpha';
  if r.phone_number_id is distinct from '1131427080050707' then
    raise exception 'phone_number_id did not land: %', r.phone_number_id;
  end if;
  if r.waba_id is distinct from '896291036765497' then
    raise exception 'waba_id did not land: %', r.waba_id;
  end if;

  -- Two different things, and the first draft of this check confused
  -- them. sends_as_self means "the number a parent sees is the academy's,
  -- not the platform's" — the whole point of setting these ids, so it
  -- must be TRUE. enabled means "actually send" — and that must still be
  -- false, because nobody has decided to message 81 real families yet.
  if not r.sends_as_self or r.sender <> 'own_number' then
    raise exception 'genalpha would still send from the platform number (sender=%)', r.sender;
  end if;
  if r.enabled then
    raise exception 'genalpha reads as live before anyone decided that';
  end if;

  -- mpp must be untouched — it is the only other tenant with ids set.
  if not exists (select 1 from whatsapp_senders()
                  where tenant_id='mpp' and phone_number_id='1274588119067440') then
    raise exception 'mpp lost its sender config';
  end if;

  raise notice 'genalpha sender configured: %, token still outstanding (sender=%)',
    r.phone_number_id, r.sender;
end $$;
