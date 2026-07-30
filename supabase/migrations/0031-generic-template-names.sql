-- ============================================================
-- 0031 · The templates are shared, so their names cannot be per-tenant
-- scope: mpp
--
-- 0030 gave Pride template names prefixed mpp_ — written an hour before
-- it emerged that ONE WhatsApp Business account will serve every
-- academy while this is being tested.
--
-- Templates belong to the WABA, not to a tenant. A shared account has
-- one set, so `mpp_fee_overdue` would either not exist for anyone else
-- or would have to be duplicated per academy with identical wording —
-- and a shared body cannot name one academy anyway, which is why the
-- academy became parameter {{2}}.
--
-- So the names are the generic ones the submission script creates:
--   fee_due_headsup · fee_due_today · fee_overdue
--
-- headerImage is left unset deliberately. The engine falls back to the
-- platform mark, which is right while one sender speaks for everyone;
-- when an academy gets its own number it sets its own here and nothing
-- else changes.
--
-- Still no behaviour change: enabled false, mode manual, dryRun true.
-- ============================================================

update tenants
   set config = jsonb_set(
     config,
     '{whatsapp,templates}',
     jsonb_build_object(
       'headsUp',  'fee_due_headsup',
       'dueToday', 'fee_due_today',
       'overdue',  'fee_overdue'))
 where id = 'mpp'
   and config->'whatsapp' is not null;

do $$
declare t jsonb; w jsonb;
begin
  select config->'whatsapp' into w from tenants where id = 'mpp';
  t := w->'templates';
  if t->>'overdue' <> 'fee_overdue' then
    raise exception 'mpp template names not updated: %', t;
  end if;
  if t::text like '%mpp\_%' then
    raise exception 'a tenant-prefixed template name survived: %', t;
  end if;
  -- the switches must not have moved
  if (w->>'enabled')::boolean or w->>'mode' <> 'manual' or not (w->>'dryRun')::boolean then
    raise exception 'whatsapp switches moved, they must stay off: %', w;
  end if;
  raise notice 'mpp template names are generic, sending still off';
end $$;
