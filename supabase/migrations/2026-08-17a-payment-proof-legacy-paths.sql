-- ============================================================
-- 2026-08-17a · A staff member could not open a payment screenshot
-- scope: shared
--
-- 0023 created the payment-proofs bucket and keyed it
-- <tenant_id>/<payment_id>.<ext>, so every policy could pivot on
-- storage.foldername(name)[1]. The manual "owner attaches a
-- screenshot" flow does write that layout, and its 8 rows read fine.
--
-- The WhatsApp inbound-proof path never did. When a parent sends a
-- screenshot, genalpha-whatsapp stores it as
--
--     <reminder_event_id>/<whatsapp_message_id>.jpg
--
-- so segment 1 is a reminder id, never a tenant id. The read policy
-- therefore denies it to the very staff it was written for. Storage
-- answers a denied read as 404 NoSuchKey, so it looks like a missing
-- file rather than a permission problem, which is why this sat unseen:
-- the manager's timeline just showed the raw object path as text and no
-- image, and the edge function — service_role, RLS not applicable —
-- kept attaching the same screenshot to the manager's WhatsApp alert
-- perfectly well. Measured before this migration, with the manager's
-- own token over the real API:
--
--     POST /storage/v1/object/sign/payment-proofs/2811/wamid….jpg
--     → 400 {"statusCode":"404","error":"not_found","code":"NoSuchKey"}
--
-- while service_role signed that identical key without complaint, and
-- storage.objects holds it (38 objects in the bucket, that one among
-- them). So the object is present and the grant is the whole story.
--
-- Two halves, and only the second one is here:
--
--   1. Going forward, genalpha-whatsapp prefixes the tenant, so new
--      proofs land at <tenant>/<reminder_event_id>/<msg>.jpg and match
--      0023's rule with no help from this file.
--
--   2. The objects already written cannot be moved from SQL. Renaming
--      storage.objects.name moves the row and not the bytes, which
--      turns a readable-but-denied object into a genuinely missing one
--      — strictly worse. So they stay where they are and this migration
--      teaches the policy who owns them.
--
-- Attribution is by lookup, not by parsing: 32 of the 38 objects are
-- referenced by a row that knows its tenant (payments.proof_path,
-- wa_flow_event_details.proof_path, admission_payment_claims.
-- proof_path). The other 6 are orphans — uploaded, with no surviving
-- row pointing at them — and they stay unreadable. That is the correct
-- answer for an object nobody can attribute, not a gap to paper over.
--
-- The map is a frozen snapshot rather than a live subquery on purpose.
-- It is a compatibility shim for a fixed set of historical keys; it
-- must not grow, and a table that cannot grow cannot drift. It also
-- keeps a shared policy from depending on a tenant schema's tables at
-- read time.
-- ============================================================

create table if not exists payment_proof_legacy_owner (
  object_name text primary key,
  tenant_id   text not null,
  mapped_at   timestamptz not null default now()
);

comment on table payment_proof_legacy_owner is
  'Frozen tenant attribution for payment-proofs objects written before '
  '2026-08-17a, when the WhatsApp inbound path keyed objects '
  '<reminder_event_id>/<msg>.<ext> with no tenant segment. New objects '
  'are tenant-prefixed and must NOT be added here.';

alter table payment_proof_legacy_owner enable row level security;
revoke all on payment_proof_legacy_owner from public, anon, authenticated;

-- Populated once, from whoever still points at the object. Every source
-- reaches a real tenant_id on a shared table; none of them assumes the
-- schema name is the tenant.
insert into payment_proof_legacy_owner (object_name, tenant_id)
select o.name, t.tenant_id
  from storage.objects o
  join lateral (
    select p.tenant_id
      from payments p
     where p.proof_path = o.name
     limit 1
  ) t on true
 where o.bucket_id = 'payment-proofs'
on conflict (object_name) do nothing;

insert into payment_proof_legacy_owner (object_name, tenant_id)
select o.name, t.tenant_id
  from storage.objects o
  join lateral (
    select w.tenant_id
      from genalpha.wa_flow_event_details d
      join wa_flow_events w on w.id = d.flow_event_id
     where d.proof_path = o.name
     limit 1
  ) t on true
 where o.bucket_id = 'payment-proofs'
on conflict (object_name) do nothing;

-- The remaining 3 come from the admission intake, whose claim rows carry
-- a legacy GenAlpha student uuid rather than members.id (bigint), so
-- there is no join back to a shared tenant_id. genalpha.
-- admission_payment_claims lives in a tenant schema and every row in it
-- is that tenant's by construction; the subquery reads the id from
-- `tenants` so this fails loudly rather than inventing an owner if that
-- row is ever gone.
insert into payment_proof_legacy_owner (object_name, tenant_id)
select o.name, (select id from tenants where id = 'genalpha')
  from storage.objects o
 where o.bucket_id = 'payment-proofs'
   and exists (select 1 from genalpha.admission_payment_claims c where c.proof_path = o.name)
on conflict (object_name) do nothing;

-- ------------------------------------------------------------
-- A policy predicate runs as the calling role, so the policy may not
-- read the map directly — authenticated has no grant on it, the
-- subquery would return nothing, and the predicate would be silently
-- false for every row. That is the shape that took Raj's timetable down
-- twice. It goes through a definer helper instead.
--
-- SECURITY DEFINER means default-PUBLIC execute, so revoke from public
-- (the pseudo-role — revoking anon alone is a no-op) before granting.
-- anon has no business here: the read policy this serves is
-- `to authenticated`, so unlike is_locked() there is no anon path that
-- calls it, and policy_fn_audit() reads public policies only.
-- ------------------------------------------------------------
create or replace function payment_proof_legacy_tenant(p_object_name text)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tenant_id
    from payment_proof_legacy_owner
   where object_name = p_object_name
$$;

comment on function payment_proof_legacy_tenant(text) is
  'Tenant that owns a pre-2026-08-17a payment-proofs object. Read by the '
  'payment_proofs_staff_r storage policy; not a general lookup.';

revoke execute on function payment_proof_legacy_tenant(text) from public, anon;
grant  execute on function payment_proof_legacy_tenant(text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Read only. Write, update and delete keep 0023's rule untouched: the
-- only thing that writes inbound proofs is the edge function running as
-- service_role, which does not consult a policy at all, and nothing
-- should gain the ability to overwrite or delete a historical proof by
-- way of a compatibility shim.
-- ------------------------------------------------------------
drop policy if exists payment_proofs_staff_r on storage.objects;
create policy payment_proofs_staff_r on storage.objects
  for select to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (
      auth_role() = 'operator'
      or (
        auth_role() = 'staff'
        and (
          (storage.foldername(name))[1] = auth_tenant()
          or payment_proof_legacy_tenant(name) = auth_tenant()
        )
      )
    )
  );

do $$
declare
  v_objects  int;
  v_mapped   int;
  v_orphans  int;
  v_foreign  int;
begin
  select count(*) into v_objects from storage.objects where bucket_id = 'payment-proofs';
  select count(*) into v_mapped  from payment_proof_legacy_owner;

  select count(*) into v_orphans
    from storage.objects o
   where o.bucket_id = 'payment-proofs'
     and (storage.foldername(o.name))[1] not in (select id from tenants)
     and not exists (select 1 from payment_proof_legacy_owner m where m.object_name = o.name);

  -- A mapped name that is not actually in the bucket would mean the map
  -- is granting reach over something this migration never looked at.
  select count(*) into v_foreign
    from payment_proof_legacy_owner m
   where not exists (
     select 1 from storage.objects o
      where o.bucket_id = 'payment-proofs' and o.name = m.object_name);

  if v_foreign > 0 then
    raise exception 'legacy map holds % names that are not payment-proofs objects', v_foreign;
  end if;
  if v_mapped + v_orphans <> v_objects then
    raise exception 'attribution does not add up: % mapped + % orphan <> % objects',
      v_mapped, v_orphans, v_objects;
  end if;
  if not exists (select 1 from payment_proof_legacy_owner where tenant_id not in (select id from tenants)) then
    null;
  else
    raise exception 'legacy map names a tenant that does not exist';
  end if;
  if (select public from storage.buckets where id = 'payment-proofs') then
    raise exception 'payment-proofs bucket is PUBLIC — these are bank screenshots';
  end if;
  if has_function_privilege('anon', 'payment_proof_legacy_tenant(text)', 'execute') then
    raise exception 'anon can execute payment_proof_legacy_tenant';
  end if;
  if not has_function_privilege('authenticated', 'payment_proof_legacy_tenant(text)', 'execute') then
    raise exception 'authenticated cannot execute payment_proof_legacy_tenant — the policy would deny every row';
  end if;

  raise notice 'payment proofs: % objects, % mapped to a tenant, % orphaned and still unreadable',
    v_objects, v_mapped, v_orphans;
end $$;
