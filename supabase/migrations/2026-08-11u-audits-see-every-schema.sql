-- ============================================================
-- 2026-08-11u · The audits stop at schema `public`
-- scope: shared
--
-- rpc_audit() and tenant_reach_audit() both filter `nspname = 'public'`.
-- That was true of the whole database when they were written. Merging
-- GenAlpha created a second schema holding tenant data and nine
-- SECURITY DEFINER functions, and every one of them is invisible to both.
--
-- Two are anon-callable right now:
--
--   genalpha.submit_admission_form       anon, no guard
--   genalpha.peek_next_admission_reg_no  anon, no guard
--
-- Both are intentional — they serve the public admission form, the same
-- way public.submit_application does. The problem is not those two. The
-- problem is that they were never REPORTED, so the next definer function
-- added to that schema will be just as silent, and the audits will keep
-- returning clean.
--
-- This is the 0010 lesson repeating in a new place. 0009 keyed on the
-- argument name `p_tenant` and missed every function that takes an id;
-- 0010 rewrote it around the real property. Here the audits key on the
-- schema name and miss every function that is not in `public`. Same
-- mistake, different column.
--
-- So both audits now scan every non-system schema, and report the schema
-- alongside the function name — a bare `submit_admission_form` in a
-- report is ambiguous now that two schemas have one.
-- ============================================================

-- ------------------------------------------------------------
-- rpc_audit(): definer functions anon can execute that touch tenant data
-- ------------------------------------------------------------
drop function if exists public.rpc_audit();
create function public.rpc_audit()
returns table (fn text, args text, touches text)
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
  with app_schemas as (
    select n.oid, n.nspname::text
      from pg_namespace n
     where n.nspname not in ('pg_catalog','information_schema','pg_toast',
                             'extensions','graphql','graphql_public','realtime',
                             'storage','vault','auth','net','cron','supabase_migrations',
                             'pgbouncer','backup')
       and n.nspname !~ '^pg_'
  ),
  tenant_tables as (
    -- A table counts as tenant data if it carries tenant_id, OR if it
    -- lives in a schema that belongs to exactly one tenant — genalpha's
    -- tables have no tenant_id column because the schema IS the scope.
    select c.relname::text as t
      from pg_class c
      join app_schemas n on n.oid = c.relnamespace
     where c.relkind in ('r','v')
       and (n.nspname <> 'public'
            or exists (select 1 from pg_attribute a
                        where a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0))
  )
  select n.nspname || '.' || p.proname,
         pg_get_function_identity_arguments(p.oid),
         (select string_agg(distinct tt.t, ', ')
            from tenant_tables tt
           where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
    from pg_proc p
    join app_schemas n on n.oid = p.pronamespace
   where p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute')
     -- Public by design. Qualified by schema, because two schemas now
     -- have a function whose job is "accept an application from a
     -- stranger" and only one of each pair is meant to be listed here.
     and (n.nspname || '.' || p.proname) <> all (array[
           'public.request_booking',
           'public.submit_application',
           'public.tenant_exists',
           'public.tenant_publishes_timetable',
           'public.sync_ingest',
           -- GenAlpha's public admission form, the same shape as
           -- public.submit_application. Writes an application; reads
           -- nothing back. Reviewed 2026-08-11.
           'genalpha.submit_admission_form',
           -- Returns only the next registration number, so a stranger
           -- can be shown "you will be #1048". It leaks the size of the
           -- academy and nothing else. Reviewed 2026-08-11.
           'genalpha.peek_next_admission_reg_no'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$$;

comment on function public.rpc_audit() is
  'SECURITY DEFINER functions anon can execute that touch tenant data, across EVERY app schema. Scanned only `public` until 2026-08-11u, which made all nine genalpha functions invisible.';
-- service_role only, matching rls_audit / policy_fn_audit / shared_fn_coverage.
-- The first draft of this migration granted it to `authenticated` as well,
-- and the widened tenant_reach_audit() below flagged it on the very first
-- dry run. The audit caught its own author over-granting an audit; that is
-- a better argument for this change than the one in the header.
revoke execute on function public.rpc_audit() from public, anon, authenticated;
grant  execute on function public.rpc_audit() to service_role;

-- ------------------------------------------------------------
-- tenant_reach_audit(): the same question about `authenticated`
-- ------------------------------------------------------------
drop function if exists public.tenant_reach_audit();
create function public.tenant_reach_audit()
returns table (
  fn text, args text, reason text,
  takes_tenant boolean, guarded boolean, verdict text
)
language sql
stable
security definer
set search_path = public
as $$
  with app_schemas as (
    select n.oid, n.nspname::text
      from pg_namespace n
     where n.nspname not in ('pg_catalog','information_schema','pg_toast',
                             'extensions','graphql','graphql_public','realtime',
                             'storage','vault','auth','net','cron','supabase_migrations',
                             'pgbouncer','backup')
       and n.nspname !~ '^pg_'
  ),
  defs as (
    select p.oid,
           n.nspname || '.' || p.proname                     as fn,
           p.proname::text                                   as bare,
           pg_get_function_identity_arguments(p.oid)         as args,
           pg_get_functiondef(p.oid)                         as src
      from pg_proc p
      join app_schemas n on n.oid = p.pronamespace
     where p.prosecdef
       and p.prokind = 'f'
       and has_function_privilege('authenticated', p.oid, 'execute')
  ),
  -- KNOWN WART, inherited from 2026-08-10n: this function's own source
  -- contains the guard names as regex literals, so it always matches
  -- itself and can never appear in its own report. Harmless today —
  -- it reads the catalogue and no tenant rows — but it means "the audit
  -- is clean" has never included the audit.
  guards as (
    select bare from defs
     where src ~* '\m(assert_staff|assert_staff_or_service|assert_operator|assert_attendance_access|auth_role|auth_tenant|is_service|auth\.uid|api_key)\M'
  ),
  resolved as (
    select d.oid, d.fn, d.bare, d.args, d.src,
           (d.bare in (select bare from guards))                       as self_guard,
           exists (select 1 from guards g
                    where g.bare <> d.bare
                      and d.src ~* ('\m' || g.bare || '\s*\(')) as callee_guard
      from defs d
  )
  select r.fn,
         r.args,
         case
           when r.args = '' then 'no arguments — operates across all tenants'
           when r.args ilike '%p_tenant%' then 'takes p_tenant, which a caller chooses'
           else 'takes an id, so the tenant is implied by the row'
         end,
         (r.args ilike '%p_tenant%'),
         (r.self_guard or r.callee_guard),
         case
           when r.self_guard or r.callee_guard then 'ok'
           when r.args = ''                     then 'REVIEW — unscoped and unguarded'
           else 'REACHABLE — any signed-in user of any tenant'
         end
    from resolved r
   where not (r.self_guard or r.callee_guard)
     and not exists (select 1 from pg_trigger t where t.tgfoid = r.oid)
     and r.fn <> all (array[
       -- public by design
       'public.request_booking','public.submit_application',
       'public.tenant_exists','public.tenant_publishes_timetable',
       -- named inside policies: revoking is_locked() took Raj's
       -- timetable down in 0011, so it must stay reachable
       'public.is_locked',
       -- event-trigger plumbing, never called directly
       'public.log_ddl','public.log_ddl_drop',
       -- platform observability; report shape, not tenant rows
       'public.cron_health_check','public.events_flowing','public.whatsapp_senders',
       'public.get_channels','public.assert_test_environment',
       -- KNOWN AND ACCEPTED, not safe. Both derive tenant_id from the
       -- booking row and enqueue sync work with no caller check. They
       -- leak no data. record_booking() calls them internally, so the
       -- fix is `revoke execute from authenticated` once the CourtSync
       -- call sites are confirmed.
       'public.propagate_block','public.propagate_unblock',
       -- GenAlpha's public admission form; see rpc_audit()
       'genalpha.submit_admission_form',
       'genalpha.peek_next_admission_reg_no'
     ])
   order by (r.args = '') desc, r.fn
$$;

comment on function public.tenant_reach_audit() is
  'SECURITY DEFINER functions a signed-in user of ANY tenant can execute without a tenant guard, across EVERY app schema.';
revoke execute on function public.tenant_reach_audit() from public, anon;
grant  execute on function public.tenant_reach_audit() to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v text; cand int;
begin
  -- Prove the widening actually widened. Before this migration both
  -- audits looked at zero functions outside public; if that is still
  -- true, the schema filter did not change and the checks below are
  -- worthless.
  select count(*) into cand
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'genalpha' and p.prosecdef and p.prokind = 'f';
  if cand < 5 then
    raise exception 'only % definer functions in genalpha — looking at the wrong place', cand;
  end if;

  -- Both audits must be clean apart from their reviewed baselines.
  select count(*) into n from rpc_audit();
  if n > 0 then
    select string_agg(fn, ', ') into v from rpc_audit();
    raise exception 'rpc_audit() has NEW findings: %', v;
  end if;

  select count(*) into n from tenant_reach_audit();
  if n > 0 then
    select string_agg(fn || '(' || args || ')', ', ') into v from tenant_reach_audit();
    raise exception 'tenant_reach_audit() has NEW findings: %', v;
  end if;

  -- An audit that cannot fire is decoration. Both of these passed
  -- cleanly through real leaks before, so each gets a canary: temporarily
  -- reachable functions MUST show up.
  if not exists (
    select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname='genalpha' and p.proname='submit_admission_form'
       and has_function_privilege('anon', p.oid, 'execute')
  ) then
    raise exception 'the genalpha admission form is no longer anon-callable — the public form is broken';
  end if;

  -- and the intake RPCs must be reachable by neither role
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='genalpha'
     and p.proname in ('finalize_renewal_intake','finalize_admission_intake',
                       'get_or_create_admission_intake_session',
                       'backfill_intake_payment_proof_path','student_paid_through_date')
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if n <> 0 then raise exception '% intake RPCs are reachable by anon/authenticated', n; end if;

  raise notice 'audits now cover every app schema; % genalpha definer functions in view, 0 findings', cand;
end $$;
