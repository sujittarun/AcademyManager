-- ============================================================
-- 2026-08-10a · GenAlpha merge, stage A: the container
-- scope: shared
--
-- GenAlpha stops being a federated tenant and becomes a native one. Its
-- data moves out of project hwxhigwaklzedxufwedv and into this database.
--
-- Nothing tenant-specific goes into public. The shared schema stays
-- generic; everything GenAlpha-only lives in its own schema, which is
-- the same pattern `backup` already uses here. If GenAlpha ever leaves,
-- `drop schema genalpha cascade` is the whole cleanup.
--
-- Source of truth: _archive/genalpha-premerge-2026-08-10/ — a verified
-- export of all 18 tables, 8,868 rows, plus the schema and GenAlpha's
-- own student_paid_through_date() for every student.
-- ============================================================

create schema if not exists genalpha;
comment on schema genalpha is
  'GenAlpha-only structures. The shared public schema stays generic; anything true of only this tenant lives here.';
revoke all on schema genalpha from public, anon;
grant usage on schema genalpha to authenticated, service_role;

-- The side table. PLATFORM.md: "Tenant-specific field -> a tenant-owned
-- table keyed on the shared row's id. Not a new column on members."
--
-- legacy_uuid is load-bearing, not archaeology: GenAlpha is uuid-keyed
-- and the platform is bigint, so this column is the bridge that lets the
-- existing app keep sending uuids after the cutover.
create table if not exists genalpha.student_details (
  member_id     bigint primary key references public.members(id) on delete cascade,
  legacy_uuid   uuid unique not null,
  reg_no        bigint,
  time_slot     text,
  jersey_size   text,
  jersey_pairs  integer,
  payment_method text,
  payment_upi_id text,
  payment_reference text,
  fee_plan      text,
  coaching_fee  numeric,
  admission_fee numeric,
  jersey_amount numeric,
  total_fee_amount numeric,
  fee_pause_days integer,
  rejoined_at   date,
  admission_id  uuid,
  added_by      text,
  updated_by    text,
  filled_by     text,
  payment_status text,
  fees_paid     boolean,
  amount_paid   numeric,
  renewals      jsonb,
  extra         jsonb,
  created_at    timestamptz default now()
);
create index if not exists genalpha_student_details_uuid_idx
  on genalpha.student_details(legacy_uuid);

alter table genalpha.student_details enable row level security;
-- Same shape as the rest of the platform: staff of this tenant only.
-- Idempotent: the schema survived the 2026-08-10k unstage on purpose, so
-- a re-merge finds the policy already there.
drop policy if exists genalpha_details_staff on genalpha.student_details;
create policy genalpha_details_staff on genalpha.student_details
  for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.student_details from public, anon;
grant select, insert, update, delete on genalpha.student_details to authenticated, service_role;

-- GenAlpha is no longer federated: its rows live here now, so
-- operator_portfolio() must read them natively rather than fall back to
-- the newest tenant_rollup event.
update tenants
   set config = (coalesce(config,'{}'::jsonb) - 'federated')
              || jsonb_build_object(
                   'sport','Cricket',
                   'city','Bengaluru',
                   'modules', jsonb_build_object('coaching',true,'whatsapp',true,
                                                 'booking',false,'courts',false,'payouts',false),
                   'features', jsonb_build_object('admissionsAI',true))
 where id = 'genalpha';

do $$
begin
  if (select config ? 'federated' from tenants where id='genalpha') then
    raise exception 'genalpha is still marked federated';
  end if;
  if to_regclass('genalpha.student_details') is null then
    raise exception 'genalpha.student_details was not created';
  end if;
  raise notice 'stage A ok';
end $$;
