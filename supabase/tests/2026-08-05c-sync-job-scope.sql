-- ============================================================
-- Behaviour test for 2026-08-05c — the sync queue is scoped to the caller
--
--   AcademyManager/scripts/run-test.sh \
--     AcademyManager/supabase/migrations/2026-08-05c-scope-sync-jobs-to-caller.sql \
--     AcademyManager/supabase/tests/2026-08-05c-sync-job-scope.sql
--
-- Run inside `begin; <migration>; <this>; rollback;`.
--
-- Reading the grant says `authenticated` may execute the function, which
-- is true both before and after the fix — it cannot tell you which rows
-- come back. So this signs in as each role in turn and counts what that
-- role actually consumed.
--
-- Two traps this file is built around:
--
-- 1. `set local role` outside a transaction block is a NO-OP, and the
--    test then passes as the owner while claiming to be staff. Every
--    leg asserts current_user first, so a silent no-op fails loudly.
--
-- 2. The verification must NOT be done while holding a tenant token.
--    sync_jobs has an RLS SELECT policy scoped to auth_tenant(), so
--    "MatchPoint's jobs are gone" and "MatchPoint's jobs are hidden
--    from me" read identically from inside a Leo session. Every count
--    is therefore taken back as the owner, and the leg held by the
--    tenant asserts only on what the function returned to it.
--
-- It seeds rows for two tenants because cross-tenant isolation cannot be
-- tested from inside one tenant. That is what makes this a shared-scope
-- file in the platform repo rather than anything a tenant repo may hold,
-- and the whole run is rolled back.
-- ============================================================

-- ------------------------------------------------------------
-- Setup, as the owner. Two pending jobs each for two academies that
-- really do run the booking module, tagged so no pre-existing row can
-- be mistaken for one of ours.
-- ------------------------------------------------------------
do $$
declare ids bigint[]; n int;
begin
  if (select count(*) from tenants where id in ('leo','matchpoint')) <> 2 then
    raise exception 'fixture missing: expected tenants leo and matchpoint';
  end if;

  insert into sync_jobs (tenant_id, channel, action, ext_ref, payload, status, next_run_at)
  select t.id, 'Playo', 'block', 'TEST-8O5C-' || t.id || '-' || g,
         jsonb_build_object('court','T9','date', ist_today()::text,'hour', 6 + g,'source','Website'),
         'pending', now() - interval '1 minute'
    from (values ('leo'),('matchpoint')) t(id), generate_series(1,2) g;

  select array_agg(id) into ids from sync_jobs where ext_ref like 'TEST-8O5C-%';
  if coalesce(array_length(ids, 1), 0) <> 4 then
    raise exception 'setup inserted % test jobs, expected 4', coalesce(array_length(ids, 1), 0);
  end if;

  -- A THIRD academy's backlog, if it has one. Leo and MatchPoint drain
  -- their own below and are excluded on purpose — this counter exists to
  -- catch a leg reaching past both of them, and would fire on a
  -- legitimate drain if it included them. Transaction-local, so it
  -- survives the role switches.
  select count(*) into n from sync_jobs
   where status = 'pending' and next_run_at <= now()
     and ext_ref not like 'TEST-8O5C-%'
     and tenant_id not in ('leo','matchpoint');
  perform set_config('t85c.third_party_pending', n::text, true);
end $$;

-- ------------------------------------------------------------
-- Leg 1 — a coach. 0039's role must reach nothing here, not even its
-- own academy's queue: a new role is admitted deliberately or not at all.
-- ------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000c0ac1","role":"authenticated","email":"coach1@rajsports.in","app_metadata":{"am_role":"coach","tenant_id":"raj"}}';

do $$
declare fails text[] := '{}'; r jsonb;
begin
  if current_user <> 'authenticated' then
    raise exception 'set local role did not take: running as %', current_user;
  end if;
  if auth_role() <> 'coach' then
    fails := fails || format('role came through as "%s", not coach', auth_role());
  end if;

  r := process_sync_jobs(100);
  if coalesce(r->>'scope','<missing>') <> 'none' then
    fails := fails || format('coach was given scope "%s"', coalesce(r->>'scope','<missing>'));
  end if;
  if (r->>'processed')::int <> 0 then
    fails := fails || format('coach drained %s jobs', r->>'processed');
  end if;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% FAILURES AS COACH\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

-- ------------------------------------------------------------
-- Leg 2 — Leo's staff. This is the defect: before 2026-08-05c this call
-- returned processed=4 and closed MatchPoint's blocks along with Leo's.
-- ------------------------------------------------------------
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000010e","role":"authenticated","email":"staff@leotennis.in","app_metadata":{"am_role":"staff","tenant_id":"leo"}}';

do $$
declare fails text[] := '{}'; r jsonb;
begin
  if current_user <> 'authenticated' then
    raise exception 'set local role did not take: running as %', current_user;
  end if;
  if auth_tenant() <> 'leo' then
    fails := fails || format('tenant came through as "%s", not leo', auth_tenant());
  end if;

  r := process_sync_jobs(100);
  if coalesce(r->>'scope','<missing>') <> 'leo' then
    fails := fails || format('leo staff were given scope "%s"', coalesce(r->>'scope','<missing>'));
  end if;
  -- The row-level proof is taken as the owner below; here we only need
  -- to know it saw Leo's two and not MatchPoint's.
  if (r->>'processed')::int < 2 then
    fails := fails || format('leo staff drained only %s jobs — their own queue did not run', r->>'processed');
  end if;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% FAILURES AS LEO STAFF\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

-- ------------------------------------------------------------
-- Back to the owner to count. Nothing below is RLS-filtered, so
-- "gone" and "hidden" can finally be told apart.
-- ------------------------------------------------------------
reset role;
set local request.jwt.claims = '';

do $$
declare fails text[] := '{}'; n int;
begin
  if current_user = 'authenticated' then
    raise exception 'reset role did not take — the counts below would be RLS-filtered';
  end if;

  select count(*) into n from sync_jobs
   where ext_ref like 'TEST-8O5C-leo-%' and status <> 'done';
  if n > 0 then fails := fails || format('%s of leo''s own jobs were left undrained', n); end if;

  select count(*) into n from sync_jobs
   where ext_ref like 'TEST-8O5C-matchpoint-%' and status <> 'pending';
  if n > 0 then
    fails := fails || format(
      'leo staff consumed %s of matchpoint''s sync jobs — CROSS-TENANT DRAIN', n);
  end if;

  -- Neither the coach nor the Leo session may have reached a THIRD
  -- academy's real backlog.
  select count(*) into n from sync_jobs
   where status = 'pending' and next_run_at <= now()
     and ext_ref not like 'TEST-8O5C-%'
     and tenant_id not in ('leo','matchpoint');
  if n < current_setting('t85c.third_party_pending')::int then
    fails := fails || format('%s pending jobs at other academies were consumed',
                             current_setting('t85c.third_party_pending')::int - n);
  end if;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% ISOLATION FAILURES\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

-- ------------------------------------------------------------
-- Leg 3 — MatchPoint's staff drain their own, and only then.
-- ------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b9","role":"authenticated","email":"staff@matchpoint.in","app_metadata":{"am_role":"staff","tenant_id":"matchpoint"}}';

do $$
declare r jsonb;
begin
  if current_user <> 'authenticated' then
    raise exception 'set local role did not take: running as %', current_user;
  end if;
  r := process_sync_jobs(100);
  if coalesce(r->>'scope','<missing>') <> 'matchpoint' then
    raise exception 'matchpoint staff were given scope "%"', coalesce(r->>'scope','<missing>');
  end if;
  if (r->>'processed')::int < 2 then
    raise exception 'matchpoint staff drained only % jobs — their own queue did not run', r->>'processed';
  end if;
end $$;

reset role;
set local request.jwt.claims = '';

do $$
declare n int;
begin
  select count(*) into n from sync_jobs
   where ext_ref like 'TEST-8O5C-%' and status <> 'done';
  if n > 0 then
    raise exception '% test jobs still pending after both academies drained their own', n;
  end if;
end $$;

-- ------------------------------------------------------------
-- Leg 4 — the operator. CourtSync is a multi-venue board, so an
-- operator must still reach every academy. A fix that scopes them to
-- auth_tenant() locks the monitor out of the thing it monitors.
-- ------------------------------------------------------------
do $$ begin
  update sync_jobs set status = 'pending', attempts = 0, next_run_at = now() - interval '1 minute'
   where ext_ref like 'TEST-8O5C-%';
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000fe","role":"authenticated","email":"operator@academymanager.in","app_metadata":{"am_role":"operator"}}';

do $$
declare r jsonb;
begin
  if current_user <> 'authenticated' then
    raise exception 'set local role did not take: running as %', current_user;
  end if;
  r := process_sync_jobs(100);
  if coalesce(r->>'scope','<missing>') <> 'all' then
    raise exception 'operator was given scope "%" — the CourtSync board would drain nothing', coalesce(r->>'scope','<missing>');
  end if;
end $$;

reset role;
set local request.jwt.claims = '';

do $$
declare n int;
begin
  select count(*) into n from sync_jobs
   where ext_ref like 'TEST-8O5C-%' and status <> 'done';
  if n > 0 then
    raise exception 'operator left % jobs undrained across the two academies', n;
  end if;
end $$;

-- ------------------------------------------------------------
-- Leg 5 — pg_cron. `drain-sync-jobs` runs `select process_sync_jobs(200)`
-- every minute with no PostgREST claims at all. This is the path that
-- runs at 2am, and it must still see all six academies.
-- ------------------------------------------------------------
do $$ begin
  update sync_jobs set status = 'pending', attempts = 0, next_run_at = now() - interval '1 minute'
   where ext_ref like 'TEST-8O5C-%';
end $$;

do $$
declare r jsonb; n int;
begin
  if not is_service() then
    raise exception 'a session with no claims did not read as the service path';
  end if;
  r := process_sync_jobs(200);
  if coalesce(r->>'scope','<missing>') <> 'all' then
    raise exception 'the cron path was given scope "%" — the queue would stop draining overnight', coalesce(r->>'scope','<missing>');
  end if;
  select count(*) into n from sync_jobs
   where ext_ref like 'TEST-8O5C-%' and status <> 'done';
  if n > 0 then raise exception 'the cron path left % jobs undrained', n; end if;
end $$;

select 'SYNC JOB SCOPE TESTS PASSED' as result;
