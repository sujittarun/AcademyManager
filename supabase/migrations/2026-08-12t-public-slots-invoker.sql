-- ============================================================
-- 2026-08-12t · public_slots stops bypassing RLS
-- scope: shared
--
-- 2026-08-12s gave the view a per-tenant gate but left it running with
-- owner rights, because bookings has no anon policy and an invoker view
-- would have shown the public booking pages nothing. That kept the
-- security advisor's ERROR, and the ERROR was fair: a definer view has
-- no policy, so nothing the platform audits can see what it exposes.
-- rls_audit() reads policies. anon_probe() reads named endpoints. Both
-- were blind to a view handing out 674 rows.
--
-- The proper fix is to stop relying on the SELECT list as the privacy
-- boundary and put the boundary where the tooling can see it.
--
-- WHY A ROW POLICY ALONE IS NOT ENOUGH. RLS filters ROWS, not COLUMNS.
-- bookings carries name, phone and amount. Grant anon a row policy and
-- nothing else, and anon can read the whole row straight off
-- /rest/v1/bookings — strictly worse than the definer view it replaces.
-- So the column grant is not a tidy-up alongside the policy; it is the
-- half that makes the policy safe.
--
--     grant select (id, tenant_id, sport, date, hour, court, status)
--
-- PostgreSQL requires column privileges for columns named in WHERE as
-- well as in the select list, so this also stops `?phone=eq.…` being
-- used as an oracle to test a number against the table.
--
-- After this the three protections are independent and all visible:
--   * the column grant bounds what anon may ever see;
--   * the policy bounds which rows, and names tenant_publishes_slots;
--   * the view keeps its narrow projection for the booking pages.
--
-- tenant_publishes_slots() is SECURITY DEFINER and executable by anon,
-- which is what a policy predicate needs — a predicate runs as the
-- caller, and one that reads `tenants` inline evaluates to false for
-- anon and silently denies every row. That is the 0007 outage.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columns anon may ever see on bookings.
--
-- The revoke comes FIRST and is the load-bearing half. anon currently
-- holds `arwdDxtm` on bookings — Supabase's default blanket grant, every
-- privilege including insert, update and delete. Nothing was stopping it
-- but the absence of a policy, and this file adds one. A column grant on
-- top of a table grant restricts nothing, so adding the policy without
-- the revoke would have published name, phone and amount to the open
-- internet. The check at the bottom of the first draft caught exactly
-- that, which is why it is written as behaviour and not as a catalogue
-- read.
--
-- Safe to revoke: the only anon paths to this table are the public_slots
-- view and request_booking(), a SECURITY DEFINER RPC that runs as its
-- owner. bookings has no anon write policy, so anon's insert/update/
-- delete grants were already dead letters.
--
-- Never widen the column list: name, phone and amount live here.
-- ------------------------------------------------------------
revoke all on public.bookings from anon;
grant select (id, tenant_id, sport, date, hour, court, status)
  on public.bookings to anon;

-- ------------------------------------------------------------
-- 2. Rows anon may see: opted-in tenants, nothing cancelled
-- ------------------------------------------------------------
drop policy if exists bookings_public_slots on public.bookings;
create policy bookings_public_slots on public.bookings
  for select to anon
  using (status <> 'cancelled' and tenant_publishes_slots(tenant_id));

-- ------------------------------------------------------------
-- 3. The view now runs as whoever asks
-- ------------------------------------------------------------
alter view public_slots set (security_invoker = true);

comment on view public_slots is
  'Anon-readable court availability, per-tenant opt-in via config.features.publicSlots. security_invoker since 2026-08-12t: the caller''s own privileges apply, bounded by the bookings_public_slots policy and by a column grant that withholds name, phone and amount.';

-- ------------------------------------------------------------
-- Checks — behaviour as anon, not the catalogue
-- ------------------------------------------------------------
do $$
declare n_leo int; n_demo int; n_mp int; n_other int; leaked text;
begin
  perform set_config('request.jwt.claims', null, true);
  perform set_config('role', 'anon', true);

  select count(*) into n_leo  from public_slots where tenant_id = 'leo';
  select count(*) into n_demo from public_slots where tenant_id = 'demo';
  select count(*) into n_mp   from public_slots where tenant_id = 'matchpoint';
  select count(*) into n_other from public_slots
   where tenant_id not in ('leo','demo','matchpoint');

  -- the withheld columns must be unreachable even on the base table
  leaked := '';
  begin
    perform phone from public.bookings limit 1;
    leaked := leaked || 'phone ';
  exception when insufficient_privilege then null;
  end;
  begin
    perform name from public.bookings limit 1;
    leaked := leaked || 'name ';
  exception when insufficient_privilege then null;
  end;
  begin
    perform amount from public.bookings limit 1;
    leaked := leaked || 'amount ';
  exception when insufficient_privilege then null;
  end;

  reset role;

  if n_leo = 0 or n_demo = 0 or n_mp = 0 then
    raise exception 'a live booking page went dark: leo=% demo=% matchpoint=%', n_leo, n_demo, n_mp;
  end if;
  if n_other > 0 then
    raise exception '% rows visible for tenants that did not opt in', n_other;
  end if;
  if leaked <> '' then
    raise exception 'anon can read withheld columns on bookings: %', leaked;
  end if;

  raise notice 'anon: leo % demo % matchpoint %, no other tenant, and name/phone/amount refused',
    n_leo, n_demo, n_mp;
end $$;

-- Staff must be unaffected — they read bookings whole, and the new
-- policy is permissive, so it must not have changed what they see.
do $$
declare n_staff int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','staff','tenant_id','leo'))::text, true);
  perform set_config('role','authenticated', true);
  select count(*) into n_staff from public.bookings where tenant_id = 'leo';
  reset role;
  perform set_config('request.jwt.claims', null, true);

  if n_staff = 0 then raise exception 'leo staff can no longer read their own bookings'; end if;
  raise notice 'leo staff still read % bookings, with every column', n_staff;
end $$;
