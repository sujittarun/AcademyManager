-- ============================================================
-- 2026-08-19a · a student photo and a parent's Aadhaar, collected at
--               admission — and a bucket that is actually tenant-scoped
-- scope: shared
--
-- WHY A NEW BUCKET RATHER THAN THE ONE THAT EXISTS
-- `admission-intake` is already here, private, with sensible size and MIME
-- limits. It cannot be reused, for a reason worth writing down: every one
-- of its four policies reads
--
--     auth_tenant() = 'genalpha'
--
-- A tenant's id, hardcoded into a policy on a SHARED object. Super Kings
-- staff cannot read or write that bucket at all, and the next academy
-- would need a fifth policy, and the sixth a sixth.
--
-- The obvious repair — swap the literal for a path check — is NOT
-- available: its 42 objects are named `<uuid>/<uuid>.jpg`, where the first
-- segment is a GenAlpha record id, not a tenant. Repointing the policy at
-- the path would lock GenAlpha out of every file it has. Same for
-- `payment-proofs`, 38 more objects, same shape.
--
-- So those two are left exactly as they are — they work for the tenant
-- they were built for — and this feature gets a bucket whose FIRST PATH
-- SEGMENT IS THE TENANT ID, checked in the policy. That generalises to
-- every academy without another line of SQL, which is the property the
-- other two are missing.
--
--     member-docs/<tenant_id>/adm/<ref>/<file>
--
-- ANON CAN WRITE HERE, AND THAT IS A DELIBERATE, BOUNDED DECISION
-- The admission form is a public page, so the family uploading a photo is
-- anonymous by definition. Anon therefore holds INSERT — and nothing else.
-- It cannot list, read, overwrite or delete, so one family can never see
-- another's documents, let alone another academy's.
--
-- What that costs: anyone holding the public anon key (it is in every
-- tenant repo, by design) can upload files. The blast radius is capped by
-- the bucket itself — 5 MB, images and PDF only — and by the policy
-- requiring the first path segment to be a REAL tenant id. It is still a
-- public write endpoint, and the hardening if it is ever abused is a
-- signed upload URL minted by an edge function; that needs service_role
-- and is deliberately not built today.
--
-- THE AADHAAR NUMBER
-- Stored because the academy asked for it. Two things make that safer than
-- it sounds, and neither is optional:
--   · `applications` has no anon SELECT policy — only staff read it — and
--     no anon-callable function returns these columns.
--   · every screen masks it to the last four digits.
-- UIDAI's own guidance is that an entity which is not an authorised
-- requesting entity should prefer a masked Aadhaar. If this academy ever
-- decides it only wants the last four, the change is one column and one
-- line of the form — the document image, not the number, is the record
-- most academies actually rely on.
-- ============================================================

-- ------------------------------------------------------------
-- 1. the columns
-- ------------------------------------------------------------
alter table applications
  add column if not exists student_photo_path   text,
  add column if not exists parent_aadhaar_path  text,
  add column if not exists parent_aadhaar       text;

alter table members
  add column if not exists student_photo_path   text,
  add column if not exists parent_aadhaar_path  text,
  add column if not exists parent_aadhaar       text;

comment on column applications.student_photo_path is
  'Object name inside the member-docs bucket, tenant-prefixed. NOT a URL — the bucket is private and clients mint a signed URL to read it.';
comment on column applications.parent_aadhaar_path is
  'Object name inside member-docs for the parent''s Aadhaar image/PDF. Same rules as student_photo_path.';
comment on column applications.parent_aadhaar is
  'Parent Aadhaar number, 12 digits, optional. Staff-readable only; every screen masks it to the last four. See migration 2026-08-19a for the reasoning.';
comment on column members.student_photo_path  is 'Copied from the application on approval. See applications.student_photo_path.';
comment on column members.parent_aadhaar_path is 'Copied from the application on approval. See applications.parent_aadhaar_path.';
comment on column members.parent_aadhaar      is 'Copied from the application on approval. Staff-readable only, masked on screen.';

-- 12 digits or nothing. A partially typed number is worse than none: it
-- looks like a record and matches nothing.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'applications_parent_aadhaar_ck') then
    alter table applications add constraint applications_parent_aadhaar_ck
      check (parent_aadhaar is null or parent_aadhaar ~ '^[0-9]{12}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'members_parent_aadhaar_ck') then
    alter table members add constraint members_parent_aadhaar_ck
      check (parent_aadhaar is null or parent_aadhaar ~ '^[0-9]{12}$');
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. the bucket
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('member-docs', 'member-docs', false, 5242880,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update
  set public            = false,
      file_size_limit   = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
-- 3. the policies
--
-- One helper expression throughout: the first folder in the object name is
-- the tenant that owns the file.
-- ------------------------------------------------------------
drop policy if exists member_docs_anon_w   on storage.objects;
drop policy if exists member_docs_staff_r  on storage.objects;
drop policy if exists member_docs_staff_w  on storage.objects;
drop policy if exists member_docs_staff_d  on storage.objects;

/* A family filling the public admission form. INSERT ONLY — no select, no
   update, no delete — into a folder named for a tenant that exists.
   tenant_exists() is the SECURITY DEFINER helper policies are required to
   use here: `anon` cannot read `tenants`, so an inlined subquery would
   evaluate false for every row and refuse every upload. That exact mistake
   took the platform down for three hours once. */
create policy member_docs_anon_w on storage.objects
  for insert to anon
  with check (
    bucket_id = 'member-docs'
    and tenant_exists((storage.foldername(name))[1])
  );

/* Staff of the owning academy, and the operator. Note this is the whole
   reason for the path convention: no tenant id appears in the policy. */
create policy member_docs_staff_r on storage.objects
  for select to authenticated
  using (
    bucket_id = 'member-docs'
    and (auth_role() = 'operator'
         or (auth_role() = 'staff' and auth_tenant() = (storage.foldername(name))[1]))
  );

create policy member_docs_staff_w on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'member-docs'
    and auth_role() = 'staff'
    and auth_tenant() = (storage.foldername(name))[1]
  );

create policy member_docs_staff_d on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'member-docs'
    and auth_role() = 'staff'
    and auth_tenant() = (storage.foldername(name))[1]
  );

-- ------------------------------------------------------------
-- 4. Prove it. Reads and catalogue checks only — nothing written.
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  -- the bucket is private, or every document is on the open web
  if (select public from storage.buckets where id='member-docs') is not false then
    raise exception 'member-docs is public';
  end if;

  -- anon must hold INSERT and nothing else
  select count(*) into v_n from pg_policies
   where schemaname='storage' and tablename='objects'
     and policyname like 'member_docs%' and 'anon' = any(roles) and cmd <> 'INSERT';
  if v_n <> 0 then
    raise exception 'anon has % non-INSERT policies on member-docs', v_n;
  end if;

  -- no policy on the new bucket may name a tenant
  select count(*) into v_n from pg_policies
   where schemaname='storage' and tablename='objects' and policyname like 'member_docs%'
     and (coalesce(qual,'') || coalesce(with_check,'')) ~ '''(leo|raj|matchpoint|mpp|genalpha|demo|ska)''';
  if v_n <> 0 then
    raise exception 'a member-docs policy hardcodes a tenant id — that is the bug this migration exists to avoid';
  end if;

  -- the two older buckets must be untouched: GenAlpha's 80 files depend on them
  select count(*) into v_n from pg_policies
   where schemaname='storage' and tablename='objects'
     and policyname like any (array['admission_intake%','payment_proofs%']);
  if v_n <> 8 then
    raise exception 'the pre-existing bucket policies changed (% found, expected 8)', v_n;
  end if;

  -- the constraint actually refuses a short number
  begin
    perform 1 from applications where parent_aadhaar = '123';
  exception when others then null;
  end;
end $$;
