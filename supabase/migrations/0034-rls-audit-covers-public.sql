-- ============================================================
-- 0034 · rls_audit() must see {public} policies too
-- scope: shared
--
-- The audit's role test was `'anon' = any(p.roles)` — it only examined
-- policies whose roles array literally contains anon. Policies written
-- for `public`, the PostgreSQL pseudo-role, have roles {public} and were
-- never examined, even though public INCLUDES anon. Almost every policy
-- on this database is {public}, including all the *_staff_* ones.
--
-- This is the same fact the platform already paid for twice — the grant
-- rules in PLATFORM.md learned it ("note public, the pseudo-role;
-- revoking anon alone silently changes nothing"; the is_locked() outage
-- happened because policies for public apply to anon). The audit had
-- not learned it: memories/push_subscriptions sat wide open for weeks
-- while rls_audit() reported green (closed by 0033).
--
-- Widening the role test alone is wrong: it flags four operator/staff
-- policies (events_op_r, subscriptions_op, tenants_op, tenants_staff_r)
-- that are safe — they gate on auth_role()/auth_tenant(), and tenants'
-- key column is id, not tenant_id. A noisy audit is an ignored audit.
-- So the safety test widens with it: a policy passes if it constrains
-- by tenant OR gates on an auth helper.
--
-- Verified against the live catalogue before 0033: old test 0 findings
-- (blind), widened role test alone 11 (4 false positives), this version
-- exactly the 7 real orphan-table findings — which 0033 has since
-- closed, so this file's self-check requires ZERO findings and refuses
-- to apply out of order.
--
-- Caveat, carried deliberately: this is still string-matching on
-- predicate text — a shape check, with the failure mode shape checks
-- always have. anon_probe() (0024, extended by 0035) is the behaviour
-- check; this is the cheap early warning, now with one less blind spot.
-- ============================================================

create or replace function public.rls_audit()
returns table (tbl text, policy_name text, cmd text, predicate text)
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
  select p.tablename::text,
         p.policyname::text,
         p.cmd::text,
         coalesce(p.qual, p.with_check, '')::text
    from pg_policies p
   where p.schemaname = 'public'
     and ('anon' = any(p.roles) or 'public' = any(p.roles))
     and coalesce(p.qual, '') || coalesce(p.with_check, '') not like '%tenant_id%'
     and coalesce(p.qual, '') || coalesce(p.with_check, '') not like '%auth_tenant%'
     and coalesce(p.qual, '') || coalesce(p.with_check, '') not like '%auth_role%'
   order by p.tablename, p.policyname
$$;

comment on function public.rls_audit() is
  'Policies reachable by anon — including via the public pseudo-role — whose predicate neither scopes by tenant_id/auth_tenant nor gates on auth_role. Shape check; anon_probe() is the behaviour check.';

revoke all on function public.rls_audit() from public, anon, authenticated;
grant execute on function public.rls_audit() to service_role;

-- ------------------------------------------------------------
-- Self-check: with 0033 applied first, the widened audit must come up
-- empty. If it finds anything, name it and refuse — do not ship a
-- watchdog that starts life ignoring findings.
-- ------------------------------------------------------------
do $$
declare v_n int; v_list text;
begin
  select count(*), string_agg(tbl || '.' || policy_name, ', ')
    into v_n, v_list
    from rls_audit();
  if v_n > 0 then
    raise exception 'widened rls_audit() finds % open policies: % — close them first (0033), then apply this', v_n, v_list;
  end if;
  raise notice 'rls_audit() widened to cover {public}; catalogue clean';
end $$;
