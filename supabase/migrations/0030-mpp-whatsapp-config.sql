-- ============================================================
-- 0030 · Make Pride visible to the WhatsApp engine — still silent
-- scope: mpp
--
-- The engine (supabase/functions/whatsapp-reminder) reads
-- tenants.config.whatsapp to decide what to do. Pride has no such key,
-- so loadConfig() falls back to enabled:false and the tenant is
-- invisible to it: /preview works, /run reports and returns, and there
-- is nowhere to put credentials when they arrive.
--
-- This adds the block in the SAME shape Raj uses, and DELIBERATELY in
-- the off position:
--
--   enabled  false   -- the master switch
--   mode     manual  -- the owner sends from the Reminders screen
--   dryRun   true    -- belt and braces
--
-- All three must flip before a single message can leave, and the engine
-- checks all three. In manual mode the sweep writes NOTHING — not even
-- a dry-run row — because a reminder_events row has to mean a parent
-- was really contacted or every delivery counter becomes fiction.
--
-- So this migration changes no behaviour whatsoever today. What it
-- changes is that turning sending on later is a config flip rather than
-- a schema change, and that the template names are written down
-- somewhere before anybody needs them at 3am.
--
-- Nothing here is a credential. The Meta token and phone-number id are
-- Edge Function secrets and never go in a table.
-- ============================================================

update tenants
   set config = config || jsonb_build_object(
     'whatsapp', jsonb_build_object(
       -- the three switches, all off
       'enabled', false,
       'mode',    'manual',
       'dryRun',  true,

       -- 15:00 IST: late enough that a parent is reachable, early
       -- enough that they can still pay the same day. Gen Alpha settled
       -- on this hour and Raj kept it.
       'sendHourIST', 15,

       -- Meta template names, one per rung. These must exist and be
       -- APPROVED in the WhatsApp Business account before mode flips to
       -- 'auto' — a business-initiated message cannot be free text.
       -- Each body takes exactly three parameters, in this order:
       --   {{1}} student name   {{2}} amount   {{3}} due date
       'templates', jsonb_build_object(
         'headsUp',  'mpp_fee_headsup',
         'dueToday', 'mpp_fee_due_today',
         'overdue',  'mpp_fee_overdue'),
       'templateLang', 'en',

       -- filled in from the Meta dashboard when the number is verified
       'wabaId',        '',
       'phoneNumberId', '',
       -- where a delivery failure is escalated, once there is one
       'managerPhone',  ''
     ))
 where id = 'mpp';

-- Fail loudly rather than leave a half-written config. 0004 is why:
-- jsonb_set with create_missing only creates the FINAL key, so a tenant
-- without the parent object silently got nothing and the migration
-- reported success. `||` merges, and this proves it merged.
do $$
declare w jsonb;
begin
  select config->'whatsapp' into w from tenants where id = 'mpp';
  if w is null then
    raise exception 'mpp whatsapp config missing after update';
  end if;
  if (w->>'enabled')::boolean or w->>'mode' <> 'manual' or not (w->>'dryRun')::boolean then
    raise exception 'mpp whatsapp must land in the OFF position: %', w;
  end if;
  if w->'templates'->>'headsUp' is null then
    raise exception 'mpp whatsapp template names missing';
  end if;
  -- the rest of the tenant must be untouched by the merge
  if (select config->>'brand' from tenants where id = 'mpp') is null then
    raise exception 'the merge clobbered the rest of mpp config';
  end if;
  raise notice 'mpp whatsapp config in place, all three switches off';
end $$;
