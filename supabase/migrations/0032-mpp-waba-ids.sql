-- ============================================================
-- 0032 · Write down the WhatsApp account and number ids
-- scope: mpp
--
-- Both are IDENTIFIERS, not credentials. The token stays an Edge
-- Function secret and never appears in a table; these two only say
-- WHICH account and WHICH number, and both are visible to anyone with
-- dashboard access anyway.
--
-- Recorded because deriving them turned out to be a dead end. A phone
-- number does not expose its parent WABA — the field does not exist —
-- and this system user's granular scopes carry no target_ids, so
-- neither debug_token nor me/businesses could answer it. Three deploys
-- went into finding that out. Writing the id down once costs nothing
-- and ends the question.
--
-- The number is shared: +91 82977 71212, verified name "AcademyManager",
-- serving every tenant while this is tested. Parents therefore see the
-- platform's name, not their academy's — acceptable for a test, not for
-- real families, and the reason each academy wants its own number
-- before this goes near one.
--
-- Sending stays off. enabled false, mode manual, dryRun true.
-- ============================================================

update tenants
   set config = jsonb_set(
     jsonb_set(config, '{whatsapp,wabaId}',        '"27634932309523953"'::jsonb),
                       '{whatsapp,phoneNumberId}', '"1274588119067440"'::jsonb)
 where id = 'mpp'
   and config->'whatsapp' is not null;

do $$
declare w jsonb;
begin
  select config->'whatsapp' into w from tenants where id = 'mpp';
  if w->>'wabaId' <> '27634932309523953' then
    raise exception 'wabaId not written: %', w->>'wabaId';
  end if;
  if w->>'phoneNumberId' <> '1274588119067440' then
    raise exception 'phoneNumberId not written: %', w->>'phoneNumberId';
  end if;
  -- the templates from 0031 must have survived a jsonb_set on siblings
  if w->'templates'->>'overdue' <> 'fee_overdue' then
    raise exception 'template names lost: %', w->'templates';
  end if;
  -- and nothing here may switch sending on
  if (w->>'enabled')::boolean or w->>'mode' <> 'manual' or not (w->>'dryRun')::boolean then
    raise exception 'sending must stay off: %', w;
  end if;
  raise notice 'mpp whatsapp ids recorded, sending still off';
end $$;
