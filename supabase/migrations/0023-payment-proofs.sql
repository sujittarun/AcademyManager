-- ============================================================
-- 0023 · Payment screenshots, off the device
-- scope: shared
--
-- The owner attaches a screenshot as proof a parent paid. Until now it
-- went to IndexedDB on the phone and nowhere else — and since the
-- reminder list became reminder_queue()'s answer, nothing carried the
-- attachment id back, so the image could never be shown again. It was
-- orphaned the moment it was saved, and lost outright whenever iOS
-- cleared the phone's storage.
--
-- A private bucket, a path per tenant, and a column on the payment.
--
-- PRIVATE, not public. These are bank screenshots: an account holder's
-- name, a UPI handle, an amount, sometimes a phone number. A public
-- bucket would put them behind a guessable URL with no session at all.
-- Reading one means asking for a signed URL with a staff session.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 5242880,
        array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update
   set public = false,
       file_size_limit = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
-- Objects are keyed <tenant_id>/<payment_id>.<ext>, so the tenant is
-- the first path segment and every policy pivots on it. storage gives
-- us that split already, as storage.foldername(name)[1].
-- ------------------------------------------------------------
drop policy if exists payment_proofs_staff_r on storage.objects;
create policy payment_proofs_staff_r on storage.objects
  for select to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (
      auth_role() = 'operator'
      or (auth_role() = 'staff' and (storage.foldername(name))[1] = auth_tenant())
    )
  );

drop policy if exists payment_proofs_staff_w on storage.objects;
create policy payment_proofs_staff_w on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'payment-proofs'
    and auth_role() = 'staff'
    and (storage.foldername(name))[1] = auth_tenant()
  );

drop policy if exists payment_proofs_staff_u on storage.objects;
create policy payment_proofs_staff_u on storage.objects
  for update to authenticated
  using (
    bucket_id = 'payment-proofs'
    and auth_role() = 'staff'
    and (storage.foldername(name))[1] = auth_tenant()
  );

drop policy if exists payment_proofs_staff_d on storage.objects;
create policy payment_proofs_staff_d on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'payment-proofs'
    and auth_role() = 'staff'
    and (storage.foldername(name))[1] = auth_tenant()
  );

-- ------------------------------------------------------------
-- The link. A column rather than a side table: one payment, at most
-- one screenshot, and a join for that would be ceremony.
--
-- record_fee_payment is deliberately NOT rewritten to take the path.
-- It is 93 lines that move money, and the attachment is not money — if
-- the second write fails you have a payment correctly recorded and an
-- unreferenced object, which is a far better failure than a rewritten
-- money function that nobody has exercised.
-- ------------------------------------------------------------
alter table payments add column if not exists proof_path text;

comment on column payments.proof_path is
  'Object key in the private payment-proofs bucket, <tenant>/<payment_id>.<ext>. Read via a signed URL.';

do $$
begin
  if not exists (select 1 from storage.buckets where id = 'payment-proofs') then
    raise exception 'payment-proofs bucket missing';
  end if;
  if (select public from storage.buckets where id = 'payment-proofs') then
    raise exception 'payment-proofs bucket is PUBLIC — these are bank screenshots';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='payments' and column_name='proof_path'
  ) then
    raise exception 'payments.proof_path missing';
  end if;
  raise notice 'payment proofs ready: private bucket + proof_path';
end $$;
