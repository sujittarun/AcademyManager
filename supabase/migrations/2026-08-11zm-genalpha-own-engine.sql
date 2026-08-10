-- ============================================================
-- 2026-08-11zm · Point GenAlpha's reminders at GenAlpha's own engine
-- scope: shared
--
-- 2026-08-11zi scheduled genalpha against the PLATFORM's
-- whatsapp-reminder, which sends a 4-parameter body with an image header.
-- Every reminder template on GenAlpha's WABA takes 2, so every send would
-- have been rejected — and its quick-reply buttons would have gone
-- nowhere, because the platform's sender handles delivery receipts and no
-- inbound messages at all.
--
-- GenAlpha's own engine is now deployed as `genalpha-whatsapp`. It matches
-- its templates, implements its ladder (-2 heads-up, day 0, +3, +5,
-- +7..+14 daily, stop at +15 with manual_followup_required), handles the
-- button taps into payment links, and alerts the manager. The jobs move
-- to it.
--
-- Same schedule: 09:30 UTC is 15:00 IST. tenants.config.sendHourIST does
-- NOT set this — the sender reads it and never uses it. The cron is the
-- only thing that decides the hour.
-- ============================================================

do $$
declare v_url text := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/genalpha-whatsapp';
begin
  perform cron.unschedule(jobname)
     from cron.job where jobname in ('genalpha-fee-reminders-daily','genalpha-fee-reminders-retry');

  perform cron.schedule('genalpha-fee-reminders-daily', '30 9 * * *', format($j$
    select net.http_post(
      url     := '%s',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-am-secret',
                   (select decrypted_secret from vault.decrypted_secrets where name = 'am_fn_secret')),
      body    := '{"action":"auto_schedule"}'::jsonb
    );
  $j$, v_url));

  perform cron.schedule('genalpha-fee-reminders-retry', '*/5 * * * *', format($j$
    select net.http_post(
      url     := '%s',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-am-secret',
                   (select decrypted_secret from vault.decrypted_secrets where name = 'am_fn_secret')),
      body    := '{"action":"retry_due_reminders"}'::jsonb
    );
  $j$, v_url));
end $$;

do $$
declare n int;
begin
  select count(*) into n from cron.job
   where jobname like 'genalpha-fee-reminders%' and active
     and command like '%genalpha-whatsapp%';
  if n <> 2 then raise exception 'only % genalpha job(s) point at the new engine', n; end if;

  -- the platform's own engine must still serve raj, untouched
  select count(*) into n from cron.job
   where jobname like 'raj-fee-reminders%' and active and command like '%whatsapp-reminder%';
  if n <> 2 then raise exception 'raj''s jobs no longer point at the platform engine'; end if;

  -- and nothing may send yet: the engine reads dry_run_mode from
  -- genalpha.system_settings, which 2026-08-11w aligned with
  -- tenants.config. Both must still say no.
  if (select (setting_value)::text::boolean from genalpha.system_settings
       where setting_key='whatsapp_reminders_enabled') is not false then
    raise exception 'genalpha.system_settings says reminders are on';
  end if;
  if (select (config#>>'{whatsapp,dryRun}')::boolean from tenants where id='genalpha') is not true then
    raise exception 'dryRun is off before anyone has tested the new engine';
  end if;

  raise notice 'genalpha reminders now run on their own engine at 15:00 IST, still not sending';
end $$;
