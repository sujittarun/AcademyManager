-- ============================================================
-- 0038 · Cross-tenant integrity — has one team's data touched another's?
-- scope: shared
--
-- RLS stops a tenant READING another tenant's rows. It does not stop a
-- bad write from LINKING them: a payment whose enrollment belongs to
-- another academy, an enrollment pointing at another academy's batch, a
-- fee rule attached to someone else's centre. Foreign keys accept all
-- of those happily — `payments.enrollment_id -> enrollments.id` says
-- nothing about tenant_id. That is the failure mode this platform gets
-- as tenant teams multiply and each ships its own writes.
--
-- So: walk the foreign-key catalogue, and for every FK where BOTH sides
-- carry tenant_id, check that child.tenant_id = parent.tenant_id.
-- Catalogue-driven on purpose — a table a team adds next month is
-- covered the day it gets its FK, with no edit here.
--
-- Nothing to configure, nothing to keep in sync: this is the data-level
-- twin of the DDL sentinel (0037). 0037 watches the schema, this
-- watches the rows.
-- ============================================================

create or replace function public.cross_tenant_integrity()
returns table (
  child_table  text,
  fk_column    text,
  parent_table text,
  bad_rows     bigint,
  sample       text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $$
declare
  r record;
  v_n bigint;
  v_sample text;
begin
  for r in
    select ch.relname::text  as child_tbl,
           pa.relname::text  as parent_tbl,
           (select a.attname from pg_attribute a
             where a.attrelid = con.conrelid  and a.attnum = con.conkey[1])::text  as child_col,
           (select a.attname from pg_attribute a
             where a.attrelid = con.confrelid and a.attnum = con.confkey[1])::text as parent_col
      from pg_constraint con
      join pg_class ch     on ch.oid = con.conrelid
      join pg_class pa     on pa.oid = con.confrelid
      join pg_namespace n  on n.oid  = ch.relnamespace and n.nspname = 'public'
     where con.contype = 'f'
       and pa.relname <> 'tenants'
       -- both sides must be tenant-scoped for the question to mean anything
       and exists (select 1 from pg_attribute a
                    where a.attrelid = con.conrelid  and a.attname = 'tenant_id' and a.attnum > 0)
       and exists (select 1 from pg_attribute a
                    where a.attrelid = con.confrelid and a.attname = 'tenant_id' and a.attnum > 0)
       -- skip the tenant_id column itself (composite tenant-scoped FKs
       -- are correct by construction)
       and (select a.attname from pg_attribute a
             where a.attrelid = con.conrelid and a.attnum = con.conkey[1]) <> 'tenant_id'
     order by 1, 3
  loop
    begin
      execute format(
        'select count(*), left(coalesce(string_agg(distinct c.tenant_id || %L || p.tenant_id, %L), %L), 200)
           from public.%I c join public.%I p on p.%I = c.%I
          where c.tenant_id is distinct from p.tenant_id',
        ' -> ', ', ', '', r.child_tbl, r.parent_tbl, r.parent_col, r.child_col)
      into v_n, v_sample;
    exception when others then
      v_n := 0; v_sample := 'check failed: ' || sqlerrm;
    end;

    if v_n > 0 or v_sample like 'check failed%' then
      child_table  := r.child_tbl;
      fk_column    := r.child_col;
      parent_table := r.parent_tbl;
      bad_rows     := v_n;
      sample       := v_sample;
      return next;
    end if;
  end loop;
end $$;

comment on function public.cross_tenant_integrity() is
  'Rows whose parent belongs to a DIFFERENT tenant. Catalogue-driven: every FK where both sides carry tenant_id, so new tables are covered automatically.';

revoke execute on function public.cross_tenant_integrity() from public, anon, authenticated;
grant execute on function public.cross_tenant_integrity() to service_role;

-- ------------------------------------------------------------
-- Hourly alarm. A finding here means one tenant's row is pointing at
-- another tenant's row — the thing that must never happen quietly.
-- ------------------------------------------------------------
create or replace function public.cron_tenant_integrity()
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_list text;
begin
  select string_agg(child_table || '.' || fk_column || ' -> ' || parent_table ||
                    ' (' || bad_rows || ')', ', ')
    into v_list
    from cross_tenant_integrity();

  if v_list is not null then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','cross_tenant','error',
              'CROSS-TENANT ROWS: ' || v_list);
  end if;
end $$;
revoke execute on function public.cron_tenant_integrity() from public, anon, authenticated;

select cron.schedule('cross-tenant-hourly', '31 * * * *',
                     $cron$select public.cron_tenant_integrity()$cron$);

-- ------------------------------------------------------------
-- Prove the checker can actually SEE a violation, rather than trusting
-- that "0 findings" means "clean". Plant one, confirm it is caught,
-- roll it back — inside this transaction, so nothing survives.
-- ------------------------------------------------------------
do $$
declare
  v_found  int;
  v_before int;
  v_a text; v_b text;
  v_mid bigint;
begin
  select count(*) into v_before from cross_tenant_integrity();
  if v_before > 0 then
    raise exception 'cross-tenant rows already exist — investigate before arming: %',
      (select string_agg(child_table || '.' || fk_column, ', ') from cross_tenant_integrity());
  end if;

  -- two tenants that both have members
  select tenant_id into v_a from members group by tenant_id order by count(*) desc limit 1;
  select tenant_id into v_b from members where tenant_id <> v_a group by tenant_id order by count(*) desc limit 1;

  if v_b is null then
    raise notice 'only one tenant has members; planting skipped, checker still armed';
    return;
  end if;

  -- plant: a member_timeline row for tenant A pointing at tenant B's member
  select id into v_mid from members where tenant_id = v_b limit 1;
  insert into member_timeline (tenant_id, member_id, kind, title)
    values (v_a, v_mid, 'system', 'sentinel probe — rolled back');

  select count(*) into v_found from cross_tenant_integrity()
   where child_table = 'member_timeline';

  -- remove the plant regardless of outcome
  delete from member_timeline where title = 'sentinel probe — rolled back';

  if v_found = 0 then
    raise exception 'checker did not notice a planted cross-tenant row — it is not working';
  end if;

  raise notice 'cross-tenant checker armed: planted violation detected and removed';
end $$;
