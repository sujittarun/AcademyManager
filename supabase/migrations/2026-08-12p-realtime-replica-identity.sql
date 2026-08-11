-- ============================================================
-- 2026-08-12p · Realtime deletes need the old row, or RLS drops them
-- scope: shared
--
-- 2026-08-12o put the eight backing tables into supabase_realtime, which
-- fixed inserts and updates. Deletes still do not arrive, and the reason
-- is not the publication.
--
-- All eight sit at REPLICA IDENTITY DEFAULT, so a DELETE writes only the
-- primary key into the WAL. Every one of them has RLS. Realtime has to
-- decide whether a given subscriber is allowed to see the deleted row —
-- and it cannot evaluate `tenant_id = auth_tenant()` against a row that
-- consists of an id and nothing else. The safe answer, and the one it
-- takes, is to deliver the event to nobody.
--
-- The result is the worst shape of bug: adding a member appears live,
-- editing one appears live, and deleting one leaves the row on screen
-- until somebody pulls to refresh. It reads as a UI bug in the client
-- rather than a replication setting in the database.
--
-- REPLICA IDENTITY FULL puts the whole pre-image in the WAL, so the old
-- row is there to test. The cost is WAL volume on UPDATE, proportional
-- to row width — these are narrow tables holding hundreds to a few
-- thousand rows across six tenants, and the reminder engine writes a
-- handful of rows a minute at peak. That is not a trade worth agonising
-- over; a roster that lies about deletions is.
--
-- Scoped deliberately to the eight tables that are actually published.
-- REPLICA IDENTITY FULL on an unpublished table is pure write cost for
-- no reader, so this must be kept in step with the publication: if a
-- table is added to supabase_realtime later, add it here too. The check
-- below fails if the two ever drift.
-- ============================================================

alter table public.members             replica identity full;
alter table public.payments            replica identity full;
alter table public.enrollments         replica identity full;
alter table public.expenses            replica identity full;
alter table public.attendance_records  replica identity full;
alter table public.reminder_events     replica identity full;
alter table genalpha.student_details   replica identity full;
alter table genalpha.payment_link_requests replica identity full;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n_pub int; n_full int; r record; drift text := '';
begin
  -- every published table must now carry a full pre-image …
  for r in
    select pt.schemaname, pt.tablename, c.relreplident
      from pg_publication_tables pt
      join pg_class c on c.relname = pt.tablename
      join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = pt.schemaname
     where pt.pubname = 'supabase_realtime'
  loop
    if r.relreplident <> 'f' then
      drift := drift || format('%s.%s is %s; ', r.schemaname, r.tablename, r.relreplident);
    end if;
  end loop;
  if drift <> '' then
    raise exception 'published but no full pre-image, so deletes will vanish: %', drift;
  end if;

  -- … and nothing unpublished should be paying the write cost
  select count(*) into n_full
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
   where c.relkind = 'r' and c.relreplident = 'f'
     and ns.nspname in ('public','genalpha')
     and not exists (
       select 1 from pg_publication_tables pt
        where pt.pubname = 'supabase_realtime'
          and pt.schemaname = ns.nspname and pt.tablename = c.relname);
  if n_full > 0 then
    raise notice '% table(s) carry REPLICA IDENTITY FULL without being published — write cost, no reader', n_full;
  end if;

  select count(*) into n_pub from pg_publication_tables where pubname = 'supabase_realtime';
  raise notice 'realtime: % tables published, all with a full pre-image', n_pub;
end $$;

-- Prove RLS still holds on the published tables, since this migration is
-- the one that starts shipping whole rows into the replication stream.
-- A wider WAL must not become a wider read.
do $$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object(
    'role','authenticated','sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','staff','tenant_id','raj'))::text, true);
  perform set_config('role','authenticated', true);

  select count(*) into n from members where tenant_id <> 'raj';
  reset role;
  perform set_config('request.jwt.claims', null, true);

  if n > 0 then
    raise exception 'a raj staff member can read % members belonging to other tenants', n;
  end if;
  raise notice 'RLS unchanged: raj staff still see only raj';
end $$;
