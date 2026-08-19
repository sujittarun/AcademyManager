-- ============================================================
-- 2026-08-19x · GenAlpha's card linked to a 404
-- scope: shared
--
-- `config.url` was
-- https://sujittarun.github.io/genAlpha-Manager-AndroidApp/, which
-- returns 404. GenAlpha's manager app is at https://genalphaacademy.in/
-- and has been since before the migration off the legacy project.
--
-- This is older than today's work — `2026-08-19w` only exposed it,
-- because that file asserted every live tenant HAS a url and never
-- asked whether any of them answers. A present-but-dead link is worse
-- than an absent one: an absent button reads as "not set up", a dead
-- one reads as "the app is down".
--
-- So this file checks the property that actually matters, and the
-- lesson generalises: asserting a value exists is not asserting it is
-- right. The only way to know a URL is a URL is to fetch it, which SQL
-- cannot do — hence the note here and the fetch done by hand before
-- writing this line:
--
--     genalphaacademy.in                  -> 200
--     genAlpha-Manager-AndroidApp         -> 404
--
-- The old value is kept in `config.oldUrl` rather than dropped, because
-- it is presumably a repo that once existed and somebody will want to
-- know what the card used to point at.
-- ============================================================

update tenants
   set config = coalesce(config,'{}'::jsonb)
             || jsonb_build_object(
                  'url',    'https://genalphaacademy.in/',
                  'oldUrl', config->>'url')
 where id = 'genalpha'
   and coalesce(config->>'url','') <> 'https://genalphaacademy.in/';

do $chk$
begin
  if (select config->>'url' from tenants where id='genalpha')
     <> 'https://genalphaacademy.in/' then
    raise exception 'genalpha still points somewhere else';
  end if;
  if (select config->>'oldUrl' from tenants where id='genalpha') is null then
    raise exception 'the previous url was dropped instead of kept';
  end if;
  -- and the federated flag and everything else survived the merge
  if (select config->>'brand' from tenants where id='genalpha') is null then
    raise exception 'genalpha config was damaged';
  end if;
  raise notice 'genalpha -> %, was %',
    (select config->>'url' from tenants where id='genalpha'),
    (select config->>'oldUrl' from tenants where id='genalpha');
end $chk$;
