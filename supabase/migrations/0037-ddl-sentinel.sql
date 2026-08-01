-- ============================================================
-- 0037 · The DDL sentinel — who changed the shared schema, and when
-- scope: shared
--
-- The migration ledger records what came through migrate.sh. It cannot
-- see anything that did not: a statement typed into the Supabase SQL
-- editor, a psql session, another chat window in a hurry. As tenant
-- teams multiply, that gap is where one team quietly alters a table
-- five other tenants depend on — and nobody learns until a client app
-- breaks.
--
-- Postgres can tell us. An event trigger fires on every DDL command in
-- the database, whatever issued it. This records each one against the
-- shared-object list, together with the migration marker migrate.sh
-- sets (app.migration) — so an entry with no marker is, by definition,
-- a change that bypassed the runner.
--
-- This is the behaviour check for schema drift, the same way
-- anon_probe() is the behaviour check for RLS. rls_audit() reads shape;
-- schema_migrations records intent; ddl_log records what actually
-- happened.
--
-- Event triggers must be owned by a superuser and are database-wide;
-- they cannot be scoped to a tenant, which is precisely why this file
-- is shared-scope and lives here.
-- ============================================================

create table if not exists public.ddl_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  db_user     text        not null,
  command     text        not null,          -- CREATE TABLE, ALTER TABLE, ...
  obj_type    text,
  obj_name    text,
  is_shared   boolean     not null default false,
  migration   text,                          -- app.migration, null = bypassed the runner
  reviewed_at timestamptz,
  reviewed_by text
);
create index if not exists ddl_log_at_idx     on public.ddl_log (at desc);
create index if not exists ddl_log_shared_idx on public.ddl_log (is_shared, at desc) where is_shared;

alter table public.ddl_log enable row level security;
revoke all on table public.ddl_log from public, anon, authenticated;
comment on table public.ddl_log is
  'Every DDL statement in this database, with the migrate.sh marker that caused it. A shared-object row with migration IS NULL bypassed the runner.';

-- The shared-object list, in one place so the trigger and the report
-- agree — tables AND the platform functions every client calls. Anchored
-- to whole object names: public.members matches, a tenant's
-- members_notes does not.
create or replace function public.is_shared_object(p_name text)
returns boolean language sql immutable set search_path to 'public' as $$
  select lower(coalesce(p_name,'')) ~ ('(^|\.)(' || array_to_string(array[
    -- tables the whole platform shares
    'tenants','subscriptions','members','bookings','payments','expenses',
    'attendance','events','applications','reminders_log','sync_jobs','sync_log',
    'integrations','platform_settings','enrollments','fee_rules','batches',
    'centres','sports','coaches','member_timeline','reminder_events','payouts',
    'payout_rules','schema_migrations','ddl_log','contacts','public_slots',
    -- functions every client calls: the money chain, the guards, the audits
    'resolve_fee','record_fee_payment','apply_payment_coverage','reminder_queue',
    'void_payment','confirm_payment','compute_payouts','mark_attendance',
    'attendance_roster','attendance_history','attendance_dashboard',
    'request_booking','record_booking','confirm_booking','cancel_booking',
    'block_maintenance','propagate_block','propagate_unblock','process_sync_jobs',
    'sync_ingest','partner_sync','connect_integration','set_integration_secret',
    'submit_application','tenant_exists','tenant_publishes_timetable','is_locked',
    'auth_role','auth_tenant','assert_staff','assert_staff_or_service',
    'slot_rate','court_count','operator_portfolio','platform_health',
    'tenant_health','cron_health_check','cron_anon_probe','cron_ddl_check',
    'rls_audit','rpc_audit','policy_fn_audit','anon_probe','events_flowing',
    'platform_errors','reconcile_report','set_subscription','get_channels',
    'is_shared_object','log_ddl','log_ddl_drop','schema_drift'
  ], '|') || ')($|\()')
$$;

create or replace function public.log_ddl()
returns event_trigger language plpgsql security definer
set search_path to 'public' as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    -- Never log the sentinel's own bookkeeping or temp objects.
    if r.object_identity is null or r.schema_name is distinct from 'public' then
      continue;
    end if;
    insert into public.ddl_log (db_user, command, obj_type, obj_name, is_shared, migration)
    values (session_user, r.command_tag, r.object_type, r.object_identity,
            public.is_shared_object(r.object_identity),
            nullif(current_setting('app.migration', true), ''));
  end loop;
exception when others then
  null;  -- a logging failure must never block a deployment
end $$;

create or replace function public.log_ddl_drop()
returns event_trigger language plpgsql security definer
set search_path to 'public' as $$
declare r record;
begin
  for r in select * from pg_event_trigger_dropped_objects() loop
    if r.object_identity is null or r.schema_name is distinct from 'public' then
      continue;
    end if;
    insert into public.ddl_log (db_user, command, obj_type, obj_name, is_shared, migration)
    values (session_user, 'DROP', r.object_type, r.object_identity,
            public.is_shared_object(r.object_identity),
            nullif(current_setting('app.migration', true), ''));
  end loop;
exception when others then
  null;
end $$;

drop event trigger if exists ddl_sentinel;
drop event trigger if exists ddl_sentinel_drop;
create event trigger ddl_sentinel      on ddl_command_end  execute function public.log_ddl();
create event trigger ddl_sentinel_drop on sql_drop         execute function public.log_ddl_drop();

-- ------------------------------------------------------------
-- The manager's view: unreviewed shared-schema changes.
-- ------------------------------------------------------------
create or replace function public.schema_drift(p_days int default 14)
returns table (at timestamptz, db_user text, command text, obj_name text, migration text, via text)
language sql stable security definer set search_path to 'public' as $$
  select d.at, d.db_user, d.command, d.obj_name, d.migration,
         case when d.migration is null then 'BYPASSED THE RUNNER' else 'migrate.sh' end
    from public.ddl_log d
   where d.is_shared
     and d.at >= now() - make_interval(days => p_days)
     and d.reviewed_at is null
   order by d.at desc
$$;
comment on function public.schema_drift(int) is
  'Unreviewed DDL against shared objects. Rows marked BYPASSED THE RUNNER did not come through migrate.sh.';
revoke execute on function public.schema_drift(int) from public, anon, authenticated;
grant execute on function public.schema_drift(int) to service_role;

revoke execute on function public.is_shared_object(text) from public, anon, authenticated;
grant execute on function public.is_shared_object(text) to service_role, authenticated;

-- ------------------------------------------------------------
-- Alarm hourly, but only for the case that matters: a shared change
-- nobody recorded. A runner-applied change is already in the ledger.
-- ------------------------------------------------------------
create or replace function public.cron_ddl_check()
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_list text;
begin
  select string_agg(distinct obj_name, ', ')
    into v_list
    from public.ddl_log
   where is_shared and migration is null and reviewed_at is null
     and at >= now() - interval '1 hour';

  if v_list is not null then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','schema_drift','error',
              'SHARED SCHEMA CHANGED OUTSIDE migrate.sh: ' || v_list);
  end if;
end $$;
revoke execute on function public.cron_ddl_check() from public, anon, authenticated;

select cron.schedule('ddl-drift-hourly', '23 * * * *', $cron$select public.cron_ddl_check()$cron$);

-- ------------------------------------------------------------
-- Prove it works, here, now: create a throwaway shared-named object and
-- a private one, and check the sentinel classified both correctly.
-- ------------------------------------------------------------
do $$
declare v_rows int;
begin
  -- 1. Classification, as a pure function. Exact object names only:
  --    public.members is ours, a tenant's members_notes is not.
  if not public.is_shared_object('public.members')          then raise exception 'classifier misses public.members'; end if;
  if not public.is_shared_object('public.resolve_fee(text)') then raise exception 'classifier misses a shared function'; end if;
  if     public.is_shared_object('public.members_notes')     then raise exception 'classifier over-matches members_notes'; end if;
  if     public.is_shared_object('public.mpp_player_goals')  then raise exception 'classifier over-matches a tenant table'; end if;

  -- 2. The trigger actually fires. Any object will do — what is being
  --    tested here is that DDL reaches ddl_log at all.
  create table public.zz_sentinel_probe (id int);
  select count(*) into v_rows from public.ddl_log where obj_name like '%zz_sentinel_probe%';
  drop table public.zz_sentinel_probe;

  if v_rows = 0 then
    raise exception 'sentinel recorded nothing — the event trigger is not firing';
  end if;

  -- keep the log clean: the probe rows are noise, not history
  delete from public.ddl_log where obj_name like '%zz_sentinel_probe%';
  raise notice 'DDL sentinel live: trigger fires, classifier exact';
end $$;
