-- ============================================================
-- 0003 · Scope the public timetable read to tenants that opted in
-- scope: shared
--
-- THE PROBLEM
--
-- migration-raj-2.sql created, for centres/batches/sports:
--
--     create policy <t>_public_r on <t> for select to anon using (active)
--
-- The reasoning in that file is sound for Raj: the landing page must show
-- a timetable to a parent who is not signed in, and those three tables
-- hold no personal data. What it misses is that the policy is BLANKET.
-- It grants anon read of the active rows of EVERY tenant, present and
-- future, because nothing in the predicate mentions tenant_id. The
-- clients filter by tenant, but a filter in the client is not a control.
--
-- Today the exposure is nil — only 'raj' has rows in those tables, which
-- is why this has never bitten. It stops being nil the moment a second
-- tenant writes a batch. The next tenant to do so is MatchPoint Pride.
-- Anyone holding any tenant's public anon key (they are in six repos, by
-- design) would then be able to read its batch structure.
--
-- THE FIX
--
-- Publishing becomes opt-in per tenant, via config.features.publicTimetable.
-- Raj is opted in below because it genuinely publishes. Everyone else —
-- including every tenant created from now on — is private by default,
-- which is the direction a default should fail in.
-- ============================================================

-- ------------------------------------------------------------
-- The predicate needs to read `tenants`, which anon cannot select from.
-- A SECURITY DEFINER helper does the lookup so the policy is evaluated
-- correctly without granting anon any sight of the tenants table.
-- ------------------------------------------------------------
create or replace function public.tenant_publishes_timetable(p_tenant text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select (t.config #>> '{features,publicTimetable}')::boolean
       from tenants t where t.id = p_tenant),
    false)
$$;

comment on function public.tenant_publishes_timetable(text) is
  'True when this tenant has opted its centres/batches/sports into anonymous read.';

grant execute on function public.tenant_publishes_timetable(text) to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Re-scope the three public-read policies.
-- ------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['centres','batches','sports'] loop
    execute format('drop policy if exists %I on %I', t || '_public_r', t);
    execute format(
      'create policy %I on %I for select to anon
         using (active and public.tenant_publishes_timetable(tenant_id))',
      t || '_public_r', t);
  end loop;
end $$;

-- Raj publishes a timetable — that is why the original policy existed.
update tenants
   set config = jsonb_set(
         coalesce(config, '{}'::jsonb),
         '{features,publicTimetable}',
         'true'::jsonb,
         true)
 where id = 'raj';

-- ------------------------------------------------------------
-- events: anon may still write (it is a write-only analytics sink, with
-- no read policy) but no longer for a tenant that does not exist, and
-- not with an unbounded name. Pollution rather than disclosure, but the
-- table is about to carry client error reports, so it is worth shaping.
-- ------------------------------------------------------------
drop policy if exists events_public_w on events;
create policy events_public_w on events
  for insert to anon
  with check (
    tenant_id is not null
    and exists (select 1 from tenants t where t.id = events.tenant_id)
    and name is not null
    and length(name) <= 64
  );

-- ------------------------------------------------------------
-- rls_audit(): catch this class of mistake next time.
--
-- A static check, deliberately — it reads policy SHAPE rather than
-- attempting to impersonate anon. Any policy granted to anon whose
-- predicate never mentions tenant_id is, by definition, not scoped to a
-- tenant. That is exactly the bug above, and it is cheap to detect.
-- ------------------------------------------------------------
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
     and 'anon' = any(p.roles)
     and coalesce(p.qual, '') || coalesce(p.with_check, '') not like '%tenant_id%'
   order by p.tablename, p.policyname
$$;

comment on function public.rls_audit() is
  'Policies readable/writable by anon that carry no tenant_id in their predicate.';

revoke all on function public.rls_audit() from anon, authenticated;
grant execute on function public.rls_audit() to service_role;

-- ------------------------------------------------------------
-- Wire it into the hourly job that already exists (cron job
-- "reconcile-check", 0 * * * *). Body below is the live definition
-- verbatim, with the audit appended — nothing existing is changed.
-- ------------------------------------------------------------
create or replace function public.cron_health_check()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_gaps int; v_failed int; v_unscoped int;
begin
  select count(*) into v_failed from sync_jobs where status='failed';
  select count(*) into v_gaps from (
    select 1 from bookings b
    join integrations i on i.tenant_id=b.tenant_id and i.enabled and i.channel<>b.source
    where b.date=current_date and b.status='confirmed' and b.court is not null
      and not exists (select 1 from sync_log sl where sl.tenant_id=b.tenant_id and sl.channel=i.channel
        and sl.action='push' and sl.status='ok'
        and sl.detail like '%'||b.court||'%'||current_date::text||'%'||b.hour||':00%')
  ) g;
  if v_gaps>0 or v_failed>0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','reconcile', case when v_failed>0 then 'error' else 'warn' end,
        v_gaps||' propagation gap(s), '||v_failed||' failed job(s)');
  end if;

  -- appended by 0003: an anon policy with no tenant_id in its predicate
  select count(*) into v_unscoped from rls_audit();
  if v_unscoped > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rls_audit','error',
        v_unscoped||' anon policy/policies with no tenant filter: '||
        (select string_agg(tbl||'.'||policy_name, ', ') from rls_audit()));
  end if;
end $function$;
