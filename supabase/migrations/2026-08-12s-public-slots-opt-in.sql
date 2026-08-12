-- ============================================================
-- 2026-08-12s · public_slots was public for every tenant, forever
-- scope: shared
--
-- The security advisor's remaining ERROR. Two of the three flagged views
-- (genalpha.students, genalpha.attendance) are the deliberate coach
-- design from 2026-08-12g — owner rights plus an in-view role guard, so
-- a coach reads the roster with contacts nulled by the database. Those
-- stay. This is the third, and it is not deliberate.
--
--     create view public_slots as
--       select id, tenant_id, sport, date, hour, court, status
--         from bookings where status <> 'cancelled';
--
-- Owner rights, granted to anon, and no tenant predicate at all. A live
-- anon request returns 674 rows across three tenants — demo 456, leo
-- 217, matchpoint 1 — in one query.
--
-- WHY THIS IS NOT SIMPLY "REVOKE IT". Leo and MatchPoint both run public
-- booking pages that read this view, and both have publicTimetable =
-- false. Gating on that flag would take two live booking pages down,
-- which is exactly the mistake 0010 made with is_locked(): revoking
-- something an anon path depends on, and finding out in production.
-- Court availability is *meant* to be public for a venue; a customer has
-- to see which slots are free. publicTimetable gates centres, batches
-- and sports, not availability, and reusing it here would be wrong even
-- if it happened not to break anything.
--
-- WHAT IS ACTUALLY WRONG is that there is no decision anywhere. The view
-- exposes every tenant's bookings by default and forever, so:
--
--   * MPP is a venue app with 0 bookings today. The first booking it
--     takes is world-readable, and nobody will have chosen that.
--   * The safety of the whole thing rests on the SELECT list. Add
--     member_id or notes to it one day and personal data ships to anon
--     instantly, with no policy anywhere to stop it, because a definer
--     view has none. rls_audit() cannot see this — it reads policies,
--     and this view has none to read. anon_probe() never asked for it.
--
-- So: an explicit per-tenant opt-in, defaulted ON for the three tenants
-- already relying on it so no live page changes, and OFF for everyone
-- else. Publishing a tenant's availability becomes a decision someone
-- makes, rather than the default nobody chose.
--
-- The select list is left exactly as it was. Widening it is the failure
-- mode this file is warning about, not an improvement to bundle in.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The gate. A definer helper, like tenant_publishes_timetable —
--    a policy or an anon-facing view must never inline a read of
--    `tenants`, because the predicate runs as the caller and silently
--    evaluates false. That cost three hours in 0007.
-- ------------------------------------------------------------
create or replace function tenant_publishes_slots(p_tenant text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((config #>> '{features,publicSlots}')::boolean, false)
    from tenants where id = p_tenant
$$;

comment on function tenant_publishes_slots(text) is
  'Whether a tenant has opted into anon-readable court availability. Separate from publicTimetable, which gates centres/batches/sports — a venue can publish free slots while keeping its timetable private.';

-- Anon MUST be able to execute this: public_slots is read by the public
-- booking page, and a gate anon cannot evaluate denies every row.
grant execute on function tenant_publishes_slots(text) to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- 2. Opt in the tenants already relying on it, so nothing goes dark
-- ------------------------------------------------------------
update tenants
   set config = jsonb_set(
         coalesce(config, '{}'::jsonb),
         '{features}',
         coalesce(config -> 'features', '{}'::jsonb) || jsonb_build_object('publicSlots', true),
         true)
 where id in ('demo', 'leo', 'matchpoint');

-- ------------------------------------------------------------
-- 3. The gated view
-- ------------------------------------------------------------
create or replace view public_slots as
  select id, tenant_id, sport, date, hour, court, status
    from bookings
   where status <> 'cancelled'
     and tenant_publishes_slots(tenant_id);

comment on view public_slots is
  'Anon-readable court availability, per-tenant opt-in via config.features.publicSlots. Owner rights on purpose: bookings has no anon policy, so an invoker view would show the public booking page nothing. That makes the SELECT list the only thing protecting privacy — never add a column that identifies a person.';

grant select on public_slots to anon, authenticated;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n_demo int; n_leo int; n_mp int; n_other int; n_total int;
begin
  -- the three that were live must be unchanged, or a booking page went dark
  select count(*) into n_demo from public_slots where tenant_id = 'demo';
  select count(*) into n_leo  from public_slots where tenant_id = 'leo';
  select count(*) into n_mp   from public_slots where tenant_id = 'matchpoint';
  if n_demo = 0 then raise exception 'demo lost its public slots'; end if;
  if n_leo  = 0 then raise exception 'leo lost its public slots — its booking page reads this view'; end if;
  if n_mp   = 0 then raise exception 'matchpoint lost its public slots'; end if;

  -- and nobody who never opted in is exposed
  select count(*) into n_other from public_slots
   where tenant_id not in ('demo','leo','matchpoint');
  if n_other > 0 then
    raise exception '% slot rows are exposed for tenants that never opted in', n_other;
  end if;

  select count(*) into n_total from public_slots;
  raise notice 'public_slots: % rows (demo %, leo %, matchpoint %), all opted in',
    n_total, n_demo, n_leo, n_mp;
end $$;

-- Prove it as anon, because a gate the caller cannot evaluate denies
-- everything, and that failure looks identical to "the venue is empty".
do $$
declare n_anon int; n_mpp int;
begin
  perform set_config('request.jwt.claims', null, true);
  perform set_config('role', 'anon', true);

  select count(*) into n_anon from public_slots;
  select count(*) into n_mpp  from public_slots where tenant_id in ('mpp','genalpha','raj');

  reset role;

  if n_anon = 0 then
    raise exception 'anon reads 0 slots — the booking pages are down';
  end if;
  if n_mpp > 0 then
    raise exception 'anon can still read % rows for a tenant that did not opt in', n_mpp;
  end if;
  raise notice 'anon reads % slots, and none belong to a tenant that did not opt in', n_anon;
end $$;
