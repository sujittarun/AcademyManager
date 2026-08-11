-- ============================================================
-- 2026-08-12o · Realtime has been publishing nothing since the cutover
-- scope: shared
--
-- supabase_realtime on this project lists ZERO tables and is not FOR ALL
-- TABLES. Legacy published three (students, student_payments,
-- academy_expenses). So every postgres_changes subscriber on the
-- platform — all six tenants, not just GenAlpha — has been receiving
-- silence.
--
-- It hid well: a realtime subscription that matches nothing looks
-- identical to a quiet database, and the apps still refresh on pull, so
-- the only symptom was staleness nobody attributed to this.
--
-- WHY THE TABLE NAMES CHANGE. GenAlpha's app subscribes to
-- public.students, public.student_payments and public.academy_expenses.
-- None of those exist in public here — they are views in the genalpha
-- schema, and logical replication cannot publish a view. Publishing the
-- names the app asks for is impossible; what gets published is the real
-- tables underneath, and the app was changed in the same pass to treat
-- an event as "something moved, refetch" rather than as a row.
--
-- That is not a workaround, it is forced: a GenAlpha student is a view
-- over members + student_details + enrollments, so no single row event
-- could ever carry one. On legacy it could, because students was a
-- table. The shape of the fix follows the shape of the schema.
--
-- BLAST RADIUS, DELIBERATE. These are shared tables, so this turns
-- realtime on for every tenant that subscribes. That is safe because
-- Supabase applies RLS to postgres_changes — a subscriber receives only
-- rows its own policies admit, which is the same guarantee as a SELECT.
-- It is still a change to a shared surface, so it is written down here
-- rather than discovered later.
--
-- genalpha.student_details is included because it carries fields the
-- roster shows (jersey size, fee plan, contact details) and a change to
-- it alone would otherwise be invisible. It is a tenant-owned table, so
-- no other tenant is affected by that one.
-- ============================================================

do $$
declare
  t text;
  wanted text[] := array[
    'public.members',              -- the roster
    'public.enrollments',          -- fee plan, renewal date, batch
    'public.payments',             -- the finance tab
    'public.expenses',             -- academy_expenses
    'public.attendance_records',   -- the register
    'public.reminder_events',      -- WhatsApp follow-ups
    'genalpha.payment_link_requests',
    'genalpha.student_details'     -- tenant-owned; jersey, plan, contacts
  ];
begin
  foreach t in array wanted loop
    -- Skip anything already published rather than erroring; the
    -- publication is shared and another migration may have added one.
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = split_part(t, '.', 1)
         and tablename  = split_part(t, '.', 2)
    ) then
      execute format('alter publication supabase_realtime add table %s', t);
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; missing text;
begin
  select count(*) into n from pg_publication_tables where pubname='supabase_realtime';
  if n < 8 then raise exception 'only % tables published, expected at least 8', n; end if;

  -- every table the app subscribes to must be there, by name
  select string_agg(x.s||'.'||x.t, ', ') into missing
    from (values ('public','members'),('public','payments'),('public','expenses'),
                 ('public','attendance_records'),('public','enrollments'),
                 ('public','reminder_events'),
                 ('genalpha','payment_link_requests'),
                 ('genalpha','student_details')) x(s, t)
   where not exists (
     select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname = x.s and tablename = x.t);
  if missing is not null then
    raise exception 'the app subscribes to these but they are not published: %', missing;
  end if;

  -- a view must never end up in here; it would fail at replication time,
  -- not at ALTER time, which is the failure mode worth preventing
  if exists (
    select 1 from pg_publication_tables pt
      join pg_class c on c.relname = pt.tablename
      join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = pt.schemaname
     where pt.pubname = 'supabase_realtime' and c.relkind <> 'r') then
    raise exception 'a non-table was added to supabase_realtime';
  end if;

  -- RLS is what keeps this safe across six tenants; assert it rather
  -- than trusting it, because publishing bypasses nothing but relies on
  -- the policies already being there
  select string_agg(c.relname, ', ') into missing
    from pg_publication_tables pt
    join pg_class c on c.relname = pt.tablename
    join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = pt.schemaname
   where pt.pubname = 'supabase_realtime' and not c.relrowsecurity;
  if missing is not null then
    raise exception 'published without RLS, so realtime would leak across tenants: %', missing;
  end if;

  raise notice 'supabase_realtime publishes % tables, all with RLS', n;
end $$;
