-- ============================================================
-- 0004 · Restore Raj's public timetable
-- scope: shared
--
-- 0003 opted Raj into the new publicTimetable flag with:
--
--   jsonb_set(config, '{features,publicTimetable}', 'true', true)
--
-- That was wrong. jsonb_set's create_missing only creates the FINAL key;
-- the intermediate object must already exist. Raj's config has
-- {city, kind, brand, rates, courts, billing, modules, whatsapp} and no
-- 'features' at all, so the path did not resolve and the update was a
-- silent no-op — leaving Raj opted OUT and its public landing page
-- reading zero centres, batches and sports.
--
-- Caught by verifying the anon read after applying rather than assuming:
--   before 0003 -> centres 5, batches 14, sports 5
--   after  0003 -> 0, 0, 0
--
-- Merging objects works whether or not 'features' exists.
-- ============================================================

update tenants
   set config = coalesce(config, '{}'::jsonb)
              || jsonb_build_object(
                   'features',
                   coalesce(config -> 'features', '{}'::jsonb)
                     || jsonb_build_object('publicTimetable', true))
 where id = 'raj';

-- Fail loudly rather than silently leaving the site down again.
do $$
begin
  if not public.tenant_publishes_timetable('raj') then
    raise exception 'raj still not opted into publicTimetable — config merge failed';
  end if;
end $$;
