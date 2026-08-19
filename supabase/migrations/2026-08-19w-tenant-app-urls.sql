-- ============================================================
-- 2026-08-19w · Four academies had no app link on their console card
-- scope: shared
--
-- The academy card links to the tenant's own app from `config.url`, and
-- only leo, mpp and genalpha had one. raj, ska, demo and mezzo showed no
-- link at all — not a broken link, no link, which is why it went
-- unnoticed: an absent button looks like a design decision.
--
-- EVERY URL HERE WAS FETCHED, NOT INFERRED. That is the whole point of
-- this file. Two of them are not what the local folder is called:
--
--     local folder            published at
--     Mezzo/               -> /mezzo-school-of-music/
--     SuperKingsAcademy/   -> /SKAcademy/
--
-- The console's launcher had guessed both from the folder name and sent
-- the owner to a 404 — while the sign-in it had just seeded worked
-- perfectly, so only the link appeared broken. Checked with a real
-- request before writing each line, and the assertion below re-states
-- the two that surprised us so a future edit cannot quietly undo them.
--
-- genalpha keeps its own domain. matchpoint is archived and gets
-- nothing: it is absent from the console by design, so a link would be
-- a link to a card nobody sees.
-- ============================================================

update tenants set config = coalesce(config,'{}'::jsonb)
     || jsonb_build_object('url', 'https://sujittarun.github.io/mezzo-school-of-music/')
 where id = 'mezzo';

update tenants set config = coalesce(config,'{}'::jsonb)
     || jsonb_build_object('url', 'https://sujittarun.github.io/SKAcademy/')
 where id = 'ska';

update tenants set config = coalesce(config,'{}'::jsonb)
     || jsonb_build_object('url', 'https://sujittarun.github.io/Rajsports/')
 where id = 'raj';

update tenants set config = coalesce(config,'{}'::jsonb)
     || jsonb_build_object('url', 'https://sujittarun.github.io/AcademyManagerDemo/')
 where id = 'demo';

do $chk$
declare n int; r record;
begin
  -- a) the two that are NOT named after their folder, stated explicitly
  if (select config->>'url' from tenants where id='mezzo')
     <> 'https://sujittarun.github.io/mezzo-school-of-music/' then
    raise exception 'mezzo publishes from mezzo-school-of-music, not Mezzo';
  end if;
  if (select config->>'url' from tenants where id='ska')
     <> 'https://sujittarun.github.io/SKAcademy/' then
    raise exception 'ska publishes from SKAcademy, not SuperKingsAcademy';
  end if;

  -- b) every live, unarchived tenant now has somewhere to click
  select count(*) into n from tenants t
   where not coalesce((t.config->>'archived')::boolean,false)
     and coalesce(t.config->>'url','') = '';
  if n > 0 then
    for r in select id from tenants t
              where not coalesce((t.config->>'archived')::boolean,false)
                and coalesce(t.config->>'url','') = '' loop
      raise notice 'still has no app url: %', r.id;
    end loop;
    raise exception '% live tenant(s) still have no app url', n;
  end if;

  -- c) nothing else in config was disturbed. jsonb `||` replaces the key
  --    it is given and leaves the rest, but "leaves the rest" is worth
  --    proving on a column that carries billing and feature flags.
  if (select config->>'website' from tenants where id='mezzo')
     is distinct from 'https://mezzoschoolofmusic.in' then
    raise exception 'mezzo lost its website key';
  end if;
  if (select config->'reminders'->>'mode' from tenants where id='mezzo')
     is distinct from 'simple' then
    raise exception 'mezzo lost its reminder rule';
  end if;

  raise notice 'app urls set for mezzo, ska, raj, demo';
end $chk$;
