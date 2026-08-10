-- ============================================================
-- 2026-08-11w · Make GenAlpha's settings screen tell the truth
-- scope: shared
--
-- 2026-08-11v seeded genalpha.system_settings from the archive and then
-- created the trigger that mirrors it into tenants.config. In that order,
-- so the seed did not fire it.
--
-- That accident landed on the safe side and it is worth being explicit
-- about why, because the other order was one line away: the archived
-- values are whatsapp_reminders_enabled=true and dry_run_mode=false,
-- captured while GenAlpha was live on its own project. Had the trigger
-- been in place, a migration whose stated job was "load 4 missing rows"
-- would have switched real reminders on for 81 real families, with dry
-- run off, on a platform whose sender was configured forty minutes
-- earlier and never tested.
--
-- What it did leave is two switches disagreeing: the app's settings
-- screen says reminders are on, the platform says they are off, and the
-- platform is the one that decides. A manager reading that screen would
-- be told something false about whether their families are being
-- messaged.
--
-- So the settings row follows tenants.config, which is the authority.
-- From here the trigger keeps them together in the other direction: a
-- manager turning reminders on in the app updates config, and sending
-- starts. That is the intended way to go live — a person, in the app,
-- on purpose.
-- ============================================================

update genalpha.system_settings
   set setting_value = to_jsonb(coalesce((select (config#>>'{whatsapp,enabled}')::boolean
                                            from tenants where id = 'genalpha'), false)),
       updated_by    = '2026-08-11w',
       updated_at    = now()
 where setting_key = 'whatsapp_reminders_enabled';

update genalpha.system_settings
   set setting_value = to_jsonb(coalesce((select (config#>>'{whatsapp,dryRun}')::boolean
                                            from tenants where id = 'genalpha'), true)),
       updated_by    = '2026-08-11w',
       updated_at    = now()
 where setting_key = 'dry_run_mode';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare s_enabled boolean; c_enabled boolean; s_dry boolean; c_dry boolean;
begin
  select (setting_value)::text::boolean into s_enabled
    from genalpha.system_settings where setting_key = 'whatsapp_reminders_enabled';
  select (setting_value)::text::boolean into s_dry
    from genalpha.system_settings where setting_key = 'dry_run_mode';
  select (config#>>'{whatsapp,enabled}')::boolean, (config#>>'{whatsapp,dryRun}')::boolean
    into c_enabled, c_dry from tenants where id = 'genalpha';

  if s_enabled is distinct from c_enabled then
    raise exception 'settings say reminders=%, config says % — still two switches', s_enabled, c_enabled;
  end if;
  if s_dry is distinct from c_dry then
    raise exception 'settings say dryRun=%, config says %', s_dry, c_dry;
  end if;

  -- Nobody has decided to go live. If this fails, read the header before
  -- changing it: it means something turned real messaging on as a side
  -- effect, which is the failure this migration exists to describe.
  if c_enabled then
    raise exception 'GenAlpha reminders are ON — no migration should have done that';
  end if;

  -- The trigger must actually work, or the next toggle in the app changes
  -- nothing and the two drift apart again. Prove it, then put it back.
  update genalpha.system_settings set setting_value = 'true'::jsonb
   where setting_key = 'whatsapp_reminders_enabled';
  select (config#>>'{whatsapp,enabled}')::boolean into c_enabled from tenants where id = 'genalpha';
  if not c_enabled then
    raise exception 'the settings trigger does not reach tenants.config';
  end if;

  update genalpha.system_settings set setting_value = 'false'::jsonb
   where setting_key = 'whatsapp_reminders_enabled';
  select (config#>>'{whatsapp,enabled}')::boolean into c_enabled from tenants where id = 'genalpha';
  if c_enabled then
    raise exception 'the trigger set reminders on and could not set them back off';
  end if;

  raise notice 'settings and config agree: reminders off, dry run on; trigger verified in both directions';
end $$;
