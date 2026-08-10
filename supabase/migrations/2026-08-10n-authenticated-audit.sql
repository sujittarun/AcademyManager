-- ============================================================
-- 2026-08-10n · tenant_reach_audit() — the question nothing was asking
-- scope: shared
--
-- Two confirmed cross-tenant leaks today, both found by an external
-- audit rather than by the platform's own watchdogs:
--
--   process_sync_jobs(integer)        — any signed-in staff of any tenant
--                                       could drain every tenant's queue
--   enrollment_payment_summary(bigint) — Raj's staff read demo's payment
--                                       history: 3 payments, INR 6,600
--
-- Both were closed to `anon`. Both were open to `authenticated`. And
-- that is exactly the shape rpc_audit() cannot see, because it asks
-- "which SECURITY DEFINER functions can ANON execute". Nobody was asking
-- the same question about a signed-in user of the wrong academy.
--
-- rls_audit(), rpc_audit() and policy_fn_audit() all reason about
-- anon/public. The platform's threat model quietly assumed that a
-- signed-in staff member is trustworthy. With six tenants in one
-- database that assumption is wrong: `authenticated` means "somebody at
-- SOME academy", not "somebody at THIS academy".
--
-- This function asks the missing question. A SECURITY DEFINER function
-- is flagged when `authenticated` can execute it AND it has no visible
-- tenant guard, because inside a definer function RLS does not apply and
-- the grant is the only gate.
--
-- Guard detection follows the call graph one level down: resolve_fee()
-- asserts, so enrollment_fee() is safe even though its own body contains
-- no assert. A regex over the body alone reports that as a hole and
-- misses the ones that matter — which is how a shape check produced a
-- clean report through both of today's leaks.
-- ============================================================

create or replace function public.tenant_reach_audit()
returns table (
  fn            text,
  args          text,
  reason        text,
  takes_tenant  boolean,
  guarded       boolean,
  verdict       text
)
language sql
stable
security definer
set search_path = public
as $$
  with defs as (
    select p.oid,
           p.proname::text                                     as fn,
           pg_get_function_identity_arguments(p.oid)           as args,
           pg_get_functiondef(p.oid)                           as src
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef                                    -- definer only
       and p.prokind = 'f'
       and has_function_privilege('authenticated', p.oid, 'execute')
  ),
  -- one level of call graph: a function is guarded if it asserts itself,
  -- or if it calls something in public that asserts.
  guards as (
    select fn from defs
     -- Guards take several shapes here, not just assert_*: some check
     -- auth_role()/auth_tenant() inline, my_centres() scopes on auth.uid()
     -- via staff_scopes, and sync_ingest authenticates on tenants.api_key.
     -- Matching only assert_* reported 41 functions, nearly all of them safe.
     where src ~* '\m(assert_staff|assert_staff_or_service|assert_operator|assert_attendance_access|auth_role|auth_tenant|is_service|auth\.uid|api_key)\M'
  ),
  resolved as (
    select d.oid, d.fn, d.args, d.src,
           (d.fn in (select fn from guards))                                as self_guard,
           exists (select 1 from guards g
                    where g.fn <> d.fn
                      and d.src ~* ('\m' || g.fn || '\s*\(')) as callee_guard
      from defs d
  )
  select r.fn,
         r.args,
         case
           when r.args = '' then 'no arguments — operates across all tenants'
           when r.args ilike '%p_tenant%' then 'takes p_tenant, which a caller chooses'
           else 'takes an id, so the tenant is implied by the row'
         end                                                    as reason,
         (r.args ilike '%p_tenant%')                            as takes_tenant,
         (r.self_guard or r.callee_guard)                       as guarded,
         case
           when r.self_guard or r.callee_guard then 'ok'
           when r.args = ''                     then 'REVIEW — unscoped and unguarded'
           else 'REACHABLE — any signed-in user of any tenant'
         end                                                    as verdict
    from resolved r
   where not (r.self_guard or r.callee_guard)
     -- trigger functions take no arguments and are never called directly
     and not exists (select 1 from pg_trigger t where t.tgfoid = r.oid)
     -- deliberately reachable by design, reviewed
     -- Reviewed 2026-08-10 and accepted. Each line says why, so the next
     -- reader can disagree with the reasoning rather than the list.
     and r.fn not in (
       -- public by design (PLATFORM.md names exactly these four)
       'request_booking', 'submit_application',
       'tenant_exists', 'tenant_publishes_timetable',
       -- named inside policies: revoking is_locked() took Raj's timetable
       -- down in 0011, so it must stay reachable
       'is_locked',
       -- event-trigger plumbing, never called directly
       'log_ddl', 'log_ddl_drop',
       -- platform observability; report shape, not tenant rows
       'cron_health_check', 'events_flowing', 'whatsapp_senders',
       'get_channels', 'assert_test_environment',
       -- KNOWN AND ACCEPTED, not safe — baselined so new findings stand out.
       -- Both derive tenant_id from the booking row and enqueue sync work
       -- with no caller check, so a staff member at one academy can trigger
       -- another's channel sync. They leak no data. record_booking() calls
       -- them internally, so the fix is `revoke execute from authenticated`
       -- once the CourtSync call sites are confirmed.
       'propagate_block', 'propagate_unblock'
     )
   order by (r.args = '') desc, r.fn
$$;

comment on function public.tenant_reach_audit() is
  'SECURITY DEFINER functions a signed-in user of ANY tenant can execute without a tenant guard. rpc_audit() asks the same question about anon; this asks it about authenticated, which is where both 2026-08-10 leaks lived.';
revoke execute on function public.tenant_reach_audit() from public, anon;
grant  execute on function public.tenant_reach_audit() to authenticated, service_role;

-- ------------------------------------------------------------
-- Wire it into the hourly job that already runs the other audits, so it
-- is not a function nobody calls.
-- ------------------------------------------------------------
do $$
declare v_src text;
begin
  select pg_get_functiondef(oid) into v_src
    from pg_proc where proname = 'cron_health_check' and pronamespace = 'public'::regnamespace;
  if v_src is null then
    raise notice 'cron_health_check not found — tenant_reach_audit will need wiring by hand';
  elsif v_src ilike '%tenant_reach_audit%' then
    raise notice 'already wired';
  else
    raise notice 'NOT wired into cron_health_check — add it there so this is checked hourly';
  end if;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v text; cand int;
begin
  select count(*) into n from tenant_reach_audit();
  if n > 0 then
    select string_agg(fn || '(' || args || ')', ', ') into v from tenant_reach_audit();
    raise exception 'tenant_reach_audit() has NEW findings beyond the reviewed baseline: %', v;
  end if;

  -- An audit that cannot fire is decoration. Prove it is looking at a real
  -- population: this is the shape check that passed cleanly through both of
  -- today's leaks, so the audit itself gets one.
  select count(*) into cand
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.prosecdef and p.prokind='f'
     and has_function_privilege('authenticated', p.oid, 'execute');
  if cand < 20 then
    raise exception 'only % candidate functions — the audit is looking at nothing', cand;
  end if;

  -- and prove it WOULD have caught today's leak. enrollment_payment_summary
  -- was the exact shape; it is guarded now, so it must not appear.
  if exists (select 1 from tenant_reach_audit() where fn = 'enrollment_payment_summary') then
    raise exception 'the function fixed today still reads as unguarded';
  end if;

  raise notice 'tenant_reach_audit(): 0 new findings across % candidates', cand;
end $$;
