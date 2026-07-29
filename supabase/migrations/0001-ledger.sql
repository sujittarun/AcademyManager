-- ============================================================
-- 0001 · The migration ledger
-- scope: shared
--
-- WHY THIS EXISTS
--
-- Until now nothing recorded which .sql files had been applied to
-- ugsklcipzyiogxynshnh. The ledger was a human habit and a printed
-- reminder at the end of migrate.sh. That is fine until the day someone
-- re-runs an older file.
--
-- Concretely: record_fee_payment() is `create or replace`-d in BOTH
-- Raj Sports/supabase/migration-raj.sql:667 and migration-raj-8.sql:89.
-- A fresh clone plus `migrate.sh supabase/migration-raj.sql` silently
-- reinstates the v1 renewal roll-forward over the v2 one. No error is
-- raised. Money arithmetic is then wrong for every coaching tenant, and
-- the only symptom is renewal dates drifting.
--
-- This table plus the sha256 check in migrate.sh makes that impossible:
-- a filename already present is refused, and a filename present with a
-- DIFFERENT hash is refused louder, because it means the file changed
-- after it was applied.
--
-- Filenames are the key, so once a file is recorded it must never be
-- renamed or moved. That is deliberate: it is why existing tenant SQL
-- stays exactly where it lives today.
-- ============================================================

create table if not exists schema_migrations (
  filename    text primary key,
  sha256      text not null,
  -- 'shared' touches tables every tenant uses. Anything else is the
  -- tenant_id it belongs to, and it must not alter shared objects.
  scope       text not null,
  applied_at  timestamptz not null default now(),
  applied_by  text not null default current_user,
  -- Free text: 'backfill' for files applied before the ledger existed.
  note        text
);

comment on table schema_migrations is
  'Every .sql applied to this project. Keyed on filename — never rename an applied file.';

create index if not exists schema_migrations_scope_idx
  on schema_migrations (scope, applied_at desc);

-- Operator-only. Tenants have no business reading the migration history,
-- and nothing in a browser should ever write to it.
alter table schema_migrations enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'schema_migrations'
      and policyname = 'schema_migrations_service_only'
  ) then
    create policy schema_migrations_service_only on schema_migrations
      for all to service_role using (true) with check (true);
  end if;
end $$;

revoke all on schema_migrations from anon, authenticated;
