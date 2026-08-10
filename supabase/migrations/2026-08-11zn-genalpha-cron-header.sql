-- ============================================================
-- 2026-08-11zn · The cron was speaking the wrong dialect
-- scope: shared
--
-- 2026-08-11zm pointed the genalpha jobs at genalpha-whatsapp but kept
-- the platform's header. Two different conventions:
--
--   platform whatsapp-reminder   x-am-secret,     vault 'am_fn_secret'
--   genalpha-whatsapp            x-cron-secret,   WHATSAPP_CRON_SECRET
--
-- Firing it returned 401 at the gateway, before the function ran. The
-- header is fixed here and the shared secret now lives in the vault as
-- 'genalpha_cron_secret', with the same value set as the function's
-- WHATSAPP_CRON_SECRET — verified equal by comparing sha256 digests, so
-- neither copy had to be printed to check them.
--
-- The secret is read out of the vault at fire time rather than written
-- into the job body, so cron.job.command holds no credential.
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
                   'x-cron-secret',
                   (select decrypted_secret from vault.decrypted_secrets where name = 'genalpha_cron_secret')),
      body    := '{"action":"auto_schedule"}'::jsonb
    );
  $j$, v_url));

  perform cron.schedule('genalpha-fee-reminders-retry', '*/5 * * * *', format($j$
    select net.http_post(
      url     := '%s',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-cron-secret',
                   (select decrypted_secret from vault.decrypted_secrets where name = 'genalpha_cron_secret')),
      body    := '{"action":"retry_due_reminders"}'::jsonb
    );
  $j$, v_url));
end $$;

do $$
declare n int;
begin
  select count(*) into n from cron.job
   where jobname like 'genalpha-fee-reminders%' and active
     and command like '%x-cron-secret%' and command like '%genalpha-whatsapp%';
  if n <> 2 then raise exception 'only % genalpha job(s) send the right header', n; end if;

  -- no credential written into the job body
  select count(*) into n from cron.job
   where jobname like 'genalpha%' and command ~ '[0-9a-f]{32}';
  if n <> 0 then raise exception 'a job body contains what looks like a raw secret'; end if;

  if not exists (select 1 from vault.secrets where name = 'genalpha_cron_secret') then
    raise exception 'genalpha_cron_secret is not in the vault';
  end if;

  -- raj untouched, still on its own header and its own engine
  select count(*) into n from cron.job
   where jobname like 'raj-fee-reminders%' and active
     and command like '%x-am-secret%' and command like '%functions/v1/whatsapp-reminder%';
  if n <> 2 then raise exception 'raj''s jobs changed'; end if;

  raise notice 'genalpha jobs now authenticate the way its engine expects';
end $$;
