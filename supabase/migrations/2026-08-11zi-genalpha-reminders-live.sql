-- ============================================================
-- 2026-08-11zi · Turn GenAlpha's reminders on, short of actually sending
-- scope: shared
--
-- The ask was enabled=true, dryRun=false. Two things stood in the way of
-- that doing what was intended, and one of them still does.
--
-- FIXED HERE. There are THREE gates in the sender, not two:
--
--     const live = cfg.enabled && cfg.mode === 'auto' && !cfg.dryRun
--
-- genalpha's mode was 'manual', so enabled=true alone would have changed
-- nothing. And no cron job existed for genalpha at all — only
-- raj-fee-reminders-daily and -retry — so even with all three gates open
-- nothing would ever have called the function. Both fixed below.
--
-- NOT FIXED, AND WHY dryRun STAYS TRUE. The platform's sender always
-- builds a body of FOUR parameters (student, academy, amount, due date)
-- and an image header. Every reminder template on GenAlpha's WABA takes
-- TWO, and utlity_fee_headsup has no header at all. Its own source says
-- what that costs:
--
--     "a template approved WITH a media header must be SENT with one, or
--      Meta rejects the message outright. The same is true of the count
--      of body variables: send five to a template approved with four and
--      every message is rejected"
--
-- All thirteen templates on that WABA were checked. Not one is a
-- 4-variable-plus-image template. So dryRun=false today would attempt 15
-- sends and Meta would reject 15 — no messages, fifteen errors against a
-- number currently rated GREEN.
--
-- The mismatch is not an accident of configuration. GenAlpha's templates
-- carry QUICK_REPLY buttons — "1 month / 3 months / 6 months / Need
-- Help" — because a GenAlpha parent chooses a plan by tapping, and its
-- own engine reads the reply. The platform's sender neither fills those
-- templates nor handles the tap. Same template NAMES on two WABAs,
-- different shapes; that is what made it look ready.
--
-- Two ways to real sending, and they are different products:
--   a) deploy GenAlpha's own 5,548-line whatsapp-reminder, which matches
--      its templates and handles the button replies; or
--   b) create 4-variable + image templates on GenAlpha's WABA and accept
--      that its parents lose the tap-to-choose flow.
--
-- Until one of those, dryRun=true is the honest setting: the whole
-- pipeline runs on schedule and writes what it WOULD have sent, so the
-- queue, the amounts and the per-student rates are all visible without
-- anything reaching a family.
-- ============================================================

update tenants
   set config = jsonb_set(
         jsonb_set(
           jsonb_set(config, '{whatsapp,enabled}', 'true'::jsonb, true),
           '{whatsapp,mode}', '"auto"'::jsonb, true),
         '{whatsapp,dryRun}', 'true'::jsonb, true)
 where id = 'genalpha';

-- ------------------------------------------------------------
-- The scheduler. Same shape and time as Raj's, which is the only
-- working example: 09:30 UTC is 15:00 IST.
--
-- sendHourIST in tenants.config is NOT what decides this. The sender
-- reads it into its config object and never looks at it again — the cron
-- schedule is the only thing that sets the hour. Worth knowing before
-- someone changes the config expecting the time to move.
-- ------------------------------------------------------------
do $$
declare v_url text := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/whatsapp-reminder';
begin
  perform cron.unschedule(jobname)
     from cron.job where jobname in ('genalpha-fee-reminders-daily','genalpha-fee-reminders-retry');

  perform cron.schedule('genalpha-fee-reminders-daily', '30 9 * * *', format($j$
    select net.http_post(
      url     := '%s/run?tenant=genalpha',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-am-secret',
                   (select decrypted_secret from vault.decrypted_secrets where name = 'am_fn_secret')),
      body    := '{}'::jsonb
    );
  $j$, v_url));

  perform cron.schedule('genalpha-fee-reminders-retry', '*/5 * * * *', format($j$
    select net.http_post(
      url     := '%s/retry?tenant=genalpha',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-am-secret',
                   (select decrypted_secret from vault.decrypted_secrets where name = 'am_fn_secret')),
      body    := '{}'::jsonb
    );
  $j$, v_url));
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare r record; n int;
begin
  select * into r from whatsapp_senders() where tenant_id = 'genalpha';

  if not r.enabled then raise exception 'genalpha is still not enabled'; end if;
  if r.mode <> 'auto' then raise exception 'mode is %, so the sender still treats it as manual', r.mode; end if;
  if r.sender <> 'own_number' then raise exception 'genalpha would not send from its own number'; end if;
  if not r.has_own_token then raise exception 'genalpha has no token'; end if;

  -- THE ONE THAT MATTERS. Nothing may reach a family until the templates
  -- match the sender. If this ever fails, read this file's header before
  -- changing the assertion.
  if (select (config#>>'{whatsapp,dryRun}')::boolean from tenants where id='genalpha') is not true then
    raise exception 'dryRun is off while GenAlpha''s templates still take 2 parameters and the sender sends 4';
  end if;

  -- both jobs exist and are live
  select count(*) into n from cron.job
   where jobname in ('genalpha-fee-reminders-daily','genalpha-fee-reminders-retry') and active;
  if n <> 2 then raise exception 'expected 2 active genalpha reminder jobs, found %', n; end if;

  if (select schedule from cron.job where jobname='genalpha-fee-reminders-daily') <> '30 9 * * *' then
    raise exception 'the daily job is not at 09:30 UTC / 15:00 IST';
  end if;

  -- Raj must be untouched: same function, same secret, adjacent job names.
  select count(*) into n from cron.job where jobname like 'raj-fee-reminders%' and active;
  if n <> 2 then raise exception 'raj''s reminder jobs changed'; end if;
  if (select (config#>>'{whatsapp,enabled}')::boolean from tenants where id='raj') is true then
    raise exception 'raj got enabled as a side effect';
  end if;

  -- and there is something for it to find
  select count(*) into n from reminder_queue('genalpha');
  raise notice 'genalpha reminders scheduled 15:00 IST daily, retry every 5 min, DRY RUN; % families in the queue', n;
end $$;
