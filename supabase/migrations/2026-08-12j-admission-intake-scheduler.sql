-- ============================================================
-- 2026-08-12j · The AgentAlpha scheduler nobody ported
-- scope: shared
--
-- The admission intake move looked complete: the tables came across (45
-- sessions, 123 messages, 24 interpretations), the `admission-intake`
-- edge function is deployed and ACTIVE, the web form points at the
-- platform and `aiIntakeEnabled` is true. Every visible piece was here.
--
-- The cron job was not. Legacy ran `admission-intake-process-due` every
-- 10 seconds; the platform has no equivalent, so `process_due` has not
-- been called since the cutover.
--
-- WHAT THAT COSTS. processDueSessions() does two things, and both had
-- stopped:
--
--   expireIdleSessions()  — a conversation a parent abandons stays
--                           'collecting' forever instead of expiring.
--   the debounce sweep    — sessions sit in 'collecting' until they have
--                           been quiet for ADMISSION_INTAKE_DEBOUNCE_
--                           SECONDS, and THEN get read by the model.
--                           That final read is the whole of AgentAlpha.
--                           Without the sweep a parent finishes typing
--                           and nothing ever happens.
--
-- It has cost nothing yet only because every session on the platform is
-- already terminal — 31 expired, 12 confirmed, 2 rejected, none
-- collecting. The first WhatsApp admission after the cutover would have
-- been the one that hung, silently, with no error anywhere.
--
-- Verified before scheduling: POST {"action":"process_due"} with the
-- vault cron secret returns 200 {"success": true, "results": []}.
--
-- The secret is read from vault inside the job body rather than written
-- into it. GenAlpha's legacy project has a cron job with a plaintext
-- service-role key sitting in cron.job.command; that is the mistake this
-- avoids repeating.
-- ============================================================

do $$
declare v_url text := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/admission-intake';
begin
  perform cron.unschedule(jobname)
     from cron.job where jobname = 'genalpha-admission-intake-due';

  -- Named for the tenant, unlike legacy's bare 'admission-intake-process-due'.
  -- Six tenants share this scheduler namespace now.
  perform cron.schedule('genalpha-admission-intake-due', '10 seconds', format($j$
    select net.http_post(
      url     := '%s',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-cron-secret',
                   (select decrypted_secret from vault.decrypted_secrets
                     where name = 'genalpha_cron_secret')),
      body    := '{"action":"process_due"}'::jsonb
    );
  $j$, v_url));
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v_sched text; n_raj int;
begin
  select count(*), max(schedule) into n, v_sched
    from cron.job where jobname = 'genalpha-admission-intake-due' and active;
  if n <> 1 then raise exception 'the intake job is not scheduled (found % active)', n; end if;
  if v_sched <> '10 seconds' then
    raise exception 'schedule is %, not the 10 seconds legacy ran', v_sched;
  end if;

  -- the secret must actually resolve, or every run 401s in silence
  if (select decrypted_secret from vault.decrypted_secrets
       where name = 'genalpha_cron_secret') is null then
    raise exception 'genalpha_cron_secret is not in the vault; the job would 401 forever';
  end if;

  -- and the command must not carry a secret in its text, which is how
  -- the legacy project ended up with a service-role key in cron.job
  if (select command from cron.job where jobname = 'genalpha-admission-intake-due')
       ~* '(sb_secret|service_role|eyJ[A-Za-z0-9_-]{20,})' then
    raise exception 'the job body contains a literal credential';
  end if;

  -- nobody else's jobs moved
  select count(*) into n_raj from cron.job where jobname like 'raj-%' and active;
  if n_raj < 2 then raise exception 'raj''s cron jobs changed'; end if;

  raise notice 'genalpha-admission-intake-due scheduled every 10s; AgentAlpha processes again';
end $$;
