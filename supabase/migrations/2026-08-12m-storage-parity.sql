-- ============================================================
-- 2026-08-12m · Storage: the objects came across, the rules did not
-- scope: shared
--
-- Both buckets hold exactly what legacy holds — admission-intake 40
-- objects / 12.2 MB, payment-proofs 35 / 2.8 MB, byte for byte. That is
-- what made this look finished. The bucket CONFIGURATION and the access
-- POLICIES are a different story, and they drifted in both directions.
--
-- 1. admission-intake HAS NO POLICIES AT ALL.
--
--    Legacy had two — "Managers read admission intake files" and
--    "Managers upload admission intake files". Neither was ported, and
--    every storage.objects policy on this project names payment-proofs.
--    With RLS on, that means a signed-in manager can neither upload an
--    attachment on the AgentAlpha intake page (intake.js calls
--    storage.from("admission-intake").upload) nor open any of the 40
--    files already there.
--
--    It looked healthy because the migration copied the objects with
--    service_role, and because the edge function reads them with
--    service_role too — so processing works and only the human is
--    locked out.
--
-- 2. admission-intake LOST ITS LIMITS. Legacy capped uploads at 15 MB
--    and allowed four types (jpeg, png, webp, pdf). Here it is unbounded
--    and accepts anything.
--
-- 3. payment-proofs GOT STRICTER THAN THE PARENTS IT SERVES. Legacy:
--    10 MB, any type. Here: 5 MB, images only. A 6 MB phone screenshot
--    fails, and a PDF receipt — which parents do send — is rejected
--    outright. The upload simply errors in front of a family trying to
--    pay.
--
-- WHAT THIS FILE KEEPS AND WHAT IT RESTORES. The mime ALLOWLIST on
-- payment-proofs is a real improvement over legacy's "any", so it stays;
-- application/pdf is added because receipts are genuinely PDFs, and the
-- limit goes back to legacy's 10 MB. admission-intake gets its 15 MB and
-- its four types back. Restoring a limit is not a regression — having
-- none is.
--
-- POLICY SHAPE. payment-proofs scopes on (storage.foldername(name))[1] =
-- auth_tenant(), which works because those objects are filed under the
-- tenant. admission-intake objects are filed under the SESSION uuid, so
-- that predicate would match nothing. The obvious fix — a subquery into
-- admission_intake_sessions — is the trap PLATFORM.md documents twice: a
-- policy predicate runs as the caller, and a subquery it cannot read
-- returns silently false, denying every row. So the bucket is scoped on
-- role plus an explicit tenant name instead, the same way a tenant-
-- specific CHECK names its tenant. If a second tenant ever adopts
-- AgentAlpha, give the paths a tenant prefix and widen this then.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Bucket limits
-- ------------------------------------------------------------
update storage.buckets
   set file_size_limit    = 15728640,   -- 15 MB, as legacy
       allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf']
 where id = 'admission-intake';

update storage.buckets
   set file_size_limit    = 10485760,   -- 10 MB, as legacy; 5 MB rejected real screenshots
       allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic',
                                  'application/pdf']
 where id = 'payment-proofs';

-- ------------------------------------------------------------
-- 2. The policies admission-intake never got
-- ------------------------------------------------------------
drop policy if exists admission_intake_staff_r on storage.objects;
drop policy if exists admission_intake_staff_w on storage.objects;
drop policy if exists admission_intake_staff_u on storage.objects;
drop policy if exists admission_intake_staff_d on storage.objects;

create policy admission_intake_staff_r on storage.objects
  for select to authenticated
  using (bucket_id = 'admission-intake'
         and (auth_role() = 'operator'
              or (auth_role() = 'staff' and auth_tenant() = 'genalpha')));

create policy admission_intake_staff_w on storage.objects
  for insert to authenticated
  with check (bucket_id = 'admission-intake'
              and auth_role() = 'staff' and auth_tenant() = 'genalpha');

create policy admission_intake_staff_u on storage.objects
  for update to authenticated
  using (bucket_id = 'admission-intake'
         and auth_role() = 'staff' and auth_tenant() = 'genalpha');

create policy admission_intake_staff_d on storage.objects
  for delete to authenticated
  using (bucket_id = 'admission-intake'
         and auth_role() = 'staff' and auth_tenant() = 'genalpha');

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v_limit bigint; v_mimes text;
begin
  -- limits are back
  select file_size_limit into v_limit from storage.buckets where id='admission-intake';
  if coalesce(v_limit,0) <> 15728640 then
    raise exception 'admission-intake limit is %, not 15 MB', v_limit;
  end if;
  select file_size_limit into v_limit from storage.buckets where id='payment-proofs';
  if coalesce(v_limit,0) <> 10485760 then
    raise exception 'payment-proofs limit is %, not 10 MB', v_limit;
  end if;

  -- a PDF receipt must be accepted again
  select array_to_string(allowed_mime_types,',') into v_mimes
    from storage.buckets where id='payment-proofs';
  if v_mimes not like '%application/pdf%' then
    raise exception 'payment-proofs still rejects PDF receipts';
  end if;

  -- four policies, and the bucket is no longer unreachable
  select count(*) into n from pg_policy pol
    join pg_class c on c.oid=pol.polrelid join pg_namespace ns on ns.oid=c.relnamespace
   where ns.nspname='storage' and c.relname='objects'
     and pol.polname like 'admission_intake_%';
  if n <> 4 then raise exception 'expected 4 admission-intake policies, found %', n; end if;

  -- payment-proofs policies untouched
  select count(*) into n from pg_policy pol
    join pg_class c on c.oid=pol.polrelid join pg_namespace ns on ns.oid=c.relnamespace
   where ns.nspname='storage' and c.relname='objects' and pol.polname like 'payment_proofs_%';
  if n <> 4 then raise exception 'payment-proofs policies changed (% found)', n; end if;

  -- nothing was deleted from either bucket
  select count(*) into n from storage.objects where bucket_id='admission-intake';
  if n <> 40 then raise exception 'admission-intake now holds % objects, not 40', n; end if;
  select count(*) into n from storage.objects where bucket_id='payment-proofs';
  if n <> 35 then raise exception 'payment-proofs now holds % objects, not 35', n; end if;
end $$;

-- Prove the read works by being a staff member, not by reading grants.
do $$
declare n_staff int; n_coach int; n_anon int;
begin
  perform set_config('request.jwt.claims', json_build_object(
    'role','authenticated','sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','staff','tenant_id','genalpha'))::text, true);
  perform set_config('role','authenticated', true);
  select count(*) into n_staff from storage.objects where bucket_id='admission-intake';

  perform set_config('request.jwt.claims', json_build_object(
    'role','authenticated','sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','coach','tenant_id','genalpha'))::text, true);
  select count(*) into n_coach from storage.objects where bucket_id='admission-intake';

  reset role;
  perform set_config('request.jwt.claims', null, true);

  if n_staff <> 40 then
    raise exception 'GenAlpha staff can see % of the 40 intake files', n_staff;
  end if;
  if n_coach <> 0 then
    raise exception 'a coach can read % admission intake files', n_coach;
  end if;
  raise notice 'staff read all 40 intake files; a coach reads 0';
end $$;
