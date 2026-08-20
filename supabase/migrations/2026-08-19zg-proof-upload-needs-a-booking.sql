-- ============================================================
-- 2026-08-19zg · a screenshot has to belong to a booking
-- scope: shared
--
-- 2026-08-19zf let an anonymous customer upload into payment-proofs when
-- the first folder named a real academy — the same shape member-docs uses.
-- Probed over HTTP with the public key immediately after, and it did what
-- it said: a file posted from Super Kings' page landed at
-- `leo/pay/x/shot.png`. Nobody can read it back (read, list, sign and
-- overwrite were all refused, and a list returns []), so this is litter
-- rather than a leak — but one academy's public page should not be able to
-- write into another's folder at all.
--
-- The stronger guard is available HERE and not in member-docs, which is
-- why the two differ. An admission document is uploaded BEFORE the
-- application row exists, so there is no id to check against. A payment
-- screenshot always comes after the booking, so the path can be required
-- to name one:
--
--   <tenant>/pay/<booking id>/<file>
--
-- and the booking must exist, belong to that tenant, be uncollected and
-- not cancelled. To scatter files you would now need real booking ids,
-- which cost a booking each and are capped at twelve pending per number.
--
-- WHY A DEFINER HELPER AND NOT `exists (select 1 from bookings …)`.
-- A policy predicate is evaluated AS THE CALLING ROLE. anon cannot see the
-- bookings table, so an inlined subquery returns nothing and the predicate
-- is silently FALSE for every upload — the policy would not fail, it would
-- deny everything, and the customer would get an unexplained error. That is
-- migration 0007 exactly, and it cost three hours of every tenant's
-- analytics. Anything a policy needs from another table goes through a
-- SECURITY DEFINER helper.
-- ============================================================

create or replace function public.booking_open_for_proof(p_tenant text, p_id text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from bookings
     where id = p_id
       and tenant_id = p_tenant
       and status <> 'cancelled'
       and paid_at is null
  )
$function$;

/* Callable by anon BY DESIGN: a storage policy for the anon role evaluates
   as anon, and a function it cannot execute makes the policy deny rather
   than fail. It answers one boolean about a booking the caller already
   holds the id for, and discloses nothing else. */
grant execute on function public.booking_open_for_proof(text, text) to public;

drop policy if exists payment_proofs_anon_w on storage.objects;
create policy payment_proofs_anon_w on storage.objects
  for insert to anon
  with check (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[2] = 'pay'
    and booking_open_for_proof((storage.foldername(name))[1],
                               (storage.foldername(name))[3])
  );

/* THE PROBE FILE IS NOT DELETED HERE, and cannot be: storage.protect_delete()
   refuses any DELETE against storage.objects from SQL, deliberately, so an
   orphaned row cannot be created by removing a record while the object
   survives. Removing `leo/pay/x/shot.png` needs the Storage API with a
   token that satisfies payment_proofs_staff_d — which means Leo's own
   staff — and this session will not mint a login inside another tenant to
   tidy up after itself. It is a 68-byte PNG that no policy lets anyone
   read; it is recorded here and in the handover so it can be removed from
   the dashboard in one click. */

do $$
declare v_open boolean;
begin
  /* The helper must refuse a made-up id — that is the whole guard. */
  if booking_open_for_proof('ska', 'B-does-not-exist') then
    raise exception 'a made-up booking id was accepted';
  end if;

  /* …and admit a real, uncollected one, or every upload silently dies. */
  select booking_open_for_proof(b.tenant_id, b.id) into v_open
    from bookings b
   where b.tenant_id = 'ska' and b.paid_at is null and b.status <> 'cancelled'
   limit 1;
  if v_open is not null and v_open is not true then
    raise exception 'a live booking was refused — every upload would fail';
  end if;
end $$;
