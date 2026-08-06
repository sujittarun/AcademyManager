-- ============================================================
-- 2026-08-05c · One tenant's staff may no longer drain another's queue
-- scope: shared
--
-- process_sync_jobs() is SECURITY DEFINER, so RLS does not apply inside
-- it, and `authenticated` holds EXECUTE. Its loop had no tenant filter:
--
--     select * from sync_jobs where status = 'pending' and next_run_at <= now()
--     order by next_run_at limit p_limit for update skip locked
--
-- So any signed-in staff member of any academy could claim and mark
-- done EVERY academy's partner block/unblock work. Verified by holding
-- a real token rather than by reading the grant:
--
--     begin;
--     select set_config('request.jwt.claims',
--       '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"leo"}}', true);
--     set local role authenticated;
--     select current_user, process_sync_jobs(1);
--     rollback;
--     -- current_user = authenticated, result = {"failed":0,"processed":0}
--
-- The queue happened to hold zero pending rows at that moment (66 jobs,
-- all leo, all done), so nothing was actually consumed. With jobs
-- queued, Leo's staff pressing "Sync partners" would silently swallow
-- MatchPoint's blocks and mark them done — the double-selling failure
-- PLATFORM.md says the platform exists to prevent, caused by the
-- platform.
--
-- WHY NOT `revoke execute from authenticated`
--
-- Three live clients call this with a staff session, and the board's
-- whole purpose is to drain the queue on demand:
--   · CourtSync/index.html:293       POST /rpc/process_sync_jobs {p_limit:50}
--   · LeoTennis/assets/js/cloud.js:203   processSyncJobs()
--   · MatchPoint/assets/js/cloud.js:225  processSyncJobs()
--     (Machaxi/assets/js/cloud.js:203 too; Machaxi is being retired.)
-- Revoking the grant would take the "Sync partners" button off three
-- boards to fix a leak that a WHERE clause closes.
--
-- So the signature and the grant are unchanged, and the scope moves
-- INSIDE the body:
--
--   service role / no JWT (pg_cron)  -> every tenant, exactly as today
--   operator                         -> every tenant
--   staff                            -> its own tenant only
--   anything else (coach, a session
--     with no tenant claim, …)       -> nothing
--
-- Four notes on that table:
--
-- 1. The operator MUST keep the full drain. CourtSync is not a tenant
--    app — it is a multi-venue board (index.html:138 admits `staff` OR
--    `operator`, and :316 fills a venue dropdown that an operator sees
--    all of). Scoping an operator to auth_tenant() would leave them
--    draining nothing, which is the "locked every real user out" half
--    of the anon_probe lesson.
--
-- 2. pg_cron's `drain-sync-jobs` (`select process_sync_jobs(200)`, every
--    minute) runs with no PostgREST claims, so is_service() is true and
--    it keeps draining all six academies. That is the path that must
--    not change, because it is the one that runs at 2am.
--
-- 3. A coach gets NOTHING, not its own tenant. 0039's rule is that a
--    new role passes nothing until someone deliberately admits it, so
--    the scope is computed from `auth_role() = 'staff'` rather than
--    from a non-empty auth_tenant().
--
-- 4. An unrecognised caller drains zero rows rather than raising. Both
--    callers already swallow errors from this RPC (`.catch(function ()
--    { return null; })`), so a raise would be invisible anyway, and a
--    filter cannot break a client that a no-op would not.
--
-- Deliberately NOT built on assert_staff(): that guard is a no-op until
-- platform_settings.lockdown is true. It is true today, but a filter
-- that silently opens itself when someone lifts lockdown to debug
-- something is not a fix. The scope here is unconditional.
--
-- ------------------------------------------------------------
-- THE WORKER IS STILL A STUB, AND THAT IS NOT FIXED HERE
-- ------------------------------------------------------------
-- `-- REAL worker: perform the partner block/unblock HTTP call here.`
-- is the entire push. The row is marked done and a sync_log 'push' line
-- is written describing a call that never happened. Checked, because a
-- migration that scopes a worker should say whether the worker works:
--
--   · LeoTennis/supabase/functions/sync-worker/index.ts is labelled
--     SCAFFOLD and its callPartner() body is commented out;
--   · it claims work via `claim_sync_jobs`, and there is no function of
--     that name in this database — so even if deployed it processes
--     nothing;
--   · all 66 sync_jobs rows are 'done' with attempts = 1, each closed
--     within the minute of its creation by the SQL stub.
--
-- So no partner HTTP has ever left this platform, and every `push` row
-- in sync_log is synthetic. That is fine while Playo/Hudle credentials
-- are demo values (only leo's integrations carry a Vault secret_id at
-- all), but it must not be discovered by someone debugging a real
-- double-booking. Recorded in comment on function below so the next
-- reader finds it in the database, not in this file.
-- ============================================================

-- ------------------------------------------------------------
-- 1 · The body, verbatim apart from the scope
-- ------------------------------------------------------------
create or replace function public.process_sync_jobs(p_limit int default 25)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  j record; v_done int := 0; v_failed int := 0;
  v_all   boolean;   -- may this caller drain every academy?
  v_scope text;      -- if not, the one academy it may drain ('' = none)
begin
  -- 2026-08-05c: SECURITY DEFINER means RLS does not apply below this
  -- line, so the queue is whatever the loop selects. Decide the reach
  -- of the caller BEFORE selecting anything.
  v_all   := is_service() or auth_role() = 'operator';
  v_scope := case when auth_role() = 'staff' then auth_tenant() else '' end;

  for j in
    select * from sync_jobs
     where status = 'pending'
       and next_run_at <= now()
       and (v_all or (v_scope <> '' and sync_jobs.tenant_id = v_scope))
    order by next_run_at limit p_limit for update skip locked
  loop
    begin
      -- REAL worker: perform the partner block/unblock HTTP call here.
      update sync_jobs set status = 'done', attempts = attempts + 1 where id = j.id;
      insert into sync_log (tenant_id, channel, action, ext_ref, status, detail)
        values (j.tenant_id, j.channel, 'push', j.ext_ref, 'ok',
          j.action || ' ' || coalesce(j.payload->>'court','') || ' ' || coalesce(j.payload->>'date','') ||
          ' ' || coalesce(j.payload->>'hour','') || ':00 (from ' || coalesce(j.payload->>'source','') || ')');
      v_done := v_done + 1;
    exception when others then
      update sync_jobs set attempts = attempts + 1,
        status = case when attempts + 1 >= 5 then 'failed' else 'pending' end,
        next_run_at = now() + ((attempts + 1) * 30 || ' seconds')::interval,
        last_error = SQLERRM
        where id = j.id;
      v_failed := v_failed + 1;
    end;
  end loop;

  -- 'scope' is new. Nothing reads the return value today (CourtSync and
  -- both bookings.html discard it), so it costs nothing, and it means a
  -- board that has quietly stopped draining can be diagnosed from one
  -- response instead of by guessing at a JWT.
  return jsonb_build_object(
    'processed', v_done,
    'failed',    v_failed,
    'scope',     case when v_all then 'all'
                      when v_scope <> '' then v_scope
                      else 'none' end);
end $$;

-- ------------------------------------------------------------
-- 2 · Grants, restated rather than changed
--
-- Already correct in the live ACL (postgres=X | authenticated=X |
-- service_role=X — no bare =X/postgres, so PUBLIC is closed). Stated
-- here so the next reader of this file does not have to go and look,
-- and so a future `create or replace` in a fresh database lands with
-- the same reach. `public` is the pseudo-role that matters; revoking
-- `anon` alone is the no-op that 0009 learned about the hard way.
--
-- Safe to revoke from PUBLIC here: no policy calls this function
-- (that is the is_locked()/0011 trap), and anon_probe() asserts it must
-- FAIL as anon, so nothing on the anonymous path depends on it.
-- ------------------------------------------------------------
revoke execute on function public.process_sync_jobs(int) from public, anon;
grant  execute on function public.process_sync_jobs(int) to authenticated, service_role;

comment on function public.process_sync_jobs(int) is
$c$Drains ready sync_jobs. Scoped to the CALLER: service role and pg_cron
drain every tenant, an operator drains every tenant, staff drain only
auth_tenant(), anyone else drains nothing (2026-08-05c — before that any
signed-in staff member drained every academy's queue).

STUB: the partner block/unblock HTTP call is not implemented. This marks
the job done and writes a sync_log 'push' row for a call that never
happened. LeoTennis/supabase/functions/sync-worker is a scaffold whose
callPartner() is commented out and which claims work via claim_sync_jobs,
a function that does not exist here. Treat every 'push' row in sync_log
as synthetic until a real worker lands.$c$;
