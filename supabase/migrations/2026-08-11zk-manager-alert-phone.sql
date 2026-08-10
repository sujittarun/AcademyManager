-- ============================================================
-- 2026-08-11zk · The manager's alert phone, out of the source
-- scope: shared
--
-- GenAlpha's reminder engine carried
--
--     const MANAGER_PAYMENT_ALERT_PHONE = "9985822772";
--
-- as a literal. That is a person's phone number in a source file, and
-- changing who gets payment alerts meant editing and redeploying a
-- 5,548-line function. It is config now, read through the same call that
-- resolves the Meta credentials.
--
-- It is not a family's number — checked against members before moving it
-- — it is the manager's own, so it is a config value rather than
-- something that has to go in the vault.
-- ============================================================

update tenants
   set config = jsonb_set(config, '{whatsapp,managerAlertPhone}',
                          '"9985822772"'::jsonb, true)
 where id = 'genalpha';

do $$
begin
  if (select config#>>'{whatsapp,managerAlertPhone}' from tenants where id='genalpha')
     <> '9985822772' then
    raise exception 'managerAlertPhone did not land';
  end if;
  -- and the sender config it sits beside is untouched
  if (select config#>>'{whatsapp,phoneNumberId}' from tenants where id='genalpha')
     <> '1131427080050707' then
    raise exception 'the sender config changed';
  end if;
  raise notice 'managerAlertPhone moved from source to config';
end $$;
