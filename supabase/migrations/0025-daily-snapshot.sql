-- ============================================================
-- 0025 · A daily snapshot of the tenant data
-- scope: shared
--
-- READ THIS BEFORE RELYING ON IT.
--
-- This is NOT a backup. It lives in the same database it is protecting.
-- If the project is lost, deleted, or its disk fails, this goes with it
-- and you have nothing.
--
-- What it does protect against is the failure that actually happened
-- today, twice: a migration doing more than intended. I deleted a
-- tenant, altered policies that took a live site down, and applied 24
-- migrations straight to production. Any one of those could have been a
-- `delete from members` with a wrong predicate, and there would have
-- been no way back.
--
-- The real fix is Pro + PITR on the project (roughly $25/month for the
-- plan, plus the PITR add-on). Until that is bought, this is the
-- difference between "restore yesterday's rows" and "gone".
--
-- Kept for 14 days. The whole dataset across five tenants is a few
-- hundred kilobytes of jsonb; it is not worth being clever about.
-- ============================================================

create schema if not exists backup;
revoke all on schema backup from anon, authenticated;

create table if not exists backup.snapshots (
  id         bigserial primary key,
  taken_at   timestamptz not null default now(),
  table_name text        not null,
  row_count  int         not null,
  rows       jsonb       not null
);

create index if not exists snapshots_taken_at on backup.snapshots (taken_at desc);

alter table backup.snapshots enable row level security;
revoke all on backup.snapshots from anon, authenticated;
revoke all on sequence backup.snapshots_id_seq from anon, authenticated;

drop policy if exists snapshots_service on backup.snapshots;
create policy snapshots_service on backup.snapshots
  for all to service_role using (true) with check (true);

comment on table backup.snapshots is
  'Daily copy of the tenant tables. NOT a backup — same database. Guards against a bad migration, not against losing the project.';

-- ------------------------------------------------------------
-- take_snapshot(): every table that holds something a tenant would
-- notice losing. Deliberately not events or sync_log — those are
-- telemetry, and regenerate.
-- ------------------------------------------------------------
create or replace function backup.take_snapshot()
returns int
language plpgsql
security definer
set search_path to 'public', 'backup'
as $function$
declare
  t     text;
  n     int;
  total int := 0;
  tables text[] := array[
    'tenants','centres','sports','batches','fee_rules',
    'members','enrollments','payments','expenses','coaches',
    'attendance','reminder_events','subscriptions'
  ];
begin
  foreach t in array tables loop
    -- A table that does not exist yet must not stop the rest; the set
    -- differs slightly between what is deployed and what is planned.
    if not exists (
      select 1 from information_schema.tables
       where table_schema = 'public' and table_name = t
    ) then
      continue;
    end if;

    execute format(
      'insert into backup.snapshots (table_name, row_count, rows)
       select %L, count(*), coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x',
      t, t
    );
    get diagnostics n = row_count;
    total := total + n;
  end loop;

  delete from backup.snapshots where taken_at < now() - interval '14 days';
  return total;
end $function$;

revoke execute on function backup.take_snapshot() from public, anon, authenticated;

-- 03:40 IST-ish, when nobody is using it.
select cron.schedule('daily-snapshot', '10 22 * * *', $cron$select backup.take_snapshot()$cron$);

-- ------------------------------------------------------------
-- Take one now, and prove it caught something real rather than
-- recording thirteen empty arrays.
-- ------------------------------------------------------------
do $$
declare v_tables int; v_members int; v_payments int;
begin
  perform backup.take_snapshot();

  select count(*) into v_tables from backup.snapshots
   where taken_at > now() - interval '1 minute';
  if v_tables = 0 then raise exception 'snapshot wrote nothing'; end if;

  select row_count into v_members  from backup.snapshots
   where table_name = 'members'  order by taken_at desc limit 1;
  select row_count into v_payments from backup.snapshots
   where table_name = 'payments' order by taken_at desc limit 1;

  if coalesce(v_members, 0) = 0 then
    raise exception 'snapshot of members is empty, but members has rows';
  end if;

  raise notice 'snapshot: % tables, % members, % payments', v_tables, v_members, v_payments;
end $$;
