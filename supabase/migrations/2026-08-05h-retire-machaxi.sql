-- ============================================================
-- 2026-08-05h · Retire the Machaxi tenant
-- scope: shared
--
-- Machaxi is no longer a client. Its app has been forked into the demo
-- product (AcademyManagerDemo, tenant 'demo'), which carries none of its
-- data. This removes the tenant's rows.
--
-- THIS IS IRREVERSIBLE ON THIS PROJECT. The free plan has no PITR and no
-- restorable daily backup. Two independent copies were made first:
--
--   1. backup.take_snapshot() -> snapshot 13, in-database, 14-day retention.
--   2. A full JSON export of every row, verified count-for-count against
--      live, at:  _archive/machaxi-2026-08-05/
--      (outside every git repo, because it holds real names, real mobile
--      numbers and two real UPI collection ids)
--
-- The export is a to_jsonb() of each record, so a restore is an insert,
-- not a reconstruction.
--
-- WHY DELETE RATHER THAN LEAVE ARCHIVED:
-- config.archived=true already kept it out of operator_portfolio(), but
-- archived is a display flag, not a privacy control. The rows still held
-- 12 real families' names and phone numbers and two live payment
-- destinations, and shared_fn_coverage(), cross_tenant_integrity() and
-- every future migration still walked them. A former client's personal
-- data should not sit in a live production database indefinitely because
-- a boolean hides it from one screen.
--
-- EVERY STATEMENT CARRIES tenant_id. Ids are global: a DELETE on a shared
-- table without tenant_id in the WHERE empties every academy. That is the
-- single most dangerous thing this file could get wrong.
-- ============================================================

do $$
declare v_before int; v_after int; v_other_before jsonb; v_other_after jsonb;
begin
  -- ------------------------------------------------------------
  -- Preflight: photograph every OTHER tenant's row counts, so the
  -- checks at the end can prove nothing outside machaxi moved. A count
  -- of machaxi's own rows proves only that the delete ran.
  -- ------------------------------------------------------------
  select jsonb_object_agg(t, n) into v_other_before from (
    select tenant_id t, count(*) n from members     where tenant_id <> 'machaxi' group by 1
    union all
    select tenant_id, count(*) from bookings     where tenant_id <> 'machaxi' group by 1
    union all
    select tenant_id, count(*) from payments     where tenant_id <> 'machaxi' group by 1
  ) x;

  select count(*) into v_before from members where tenant_id = 'machaxi';
  if v_before <> 12 then
    raise exception 'expected 12 machaxi members, found % — the export may not match what is here', v_before;
  end if;

  -- ------------------------------------------------------------
  -- Delete, children first.
  -- ------------------------------------------------------------
  delete from attendance_records where tenant_id = 'machaxi';
  delete from sessions            where tenant_id = 'machaxi';
  delete from reminder_events     where tenant_id = 'machaxi';
  delete from payments            where tenant_id = 'machaxi';
  delete from enrollments         where tenant_id = 'machaxi';
  delete from attendance          where tenant_id = 'machaxi';
  delete from reminders_log       where tenant_id = 'machaxi';
  delete from members             where tenant_id = 'machaxi';
  delete from fee_rules           where tenant_id = 'machaxi';
  delete from payout_rules        where tenant_id = 'machaxi';
  delete from batches             where tenant_id = 'machaxi';
  delete from coaches             where tenant_id = 'machaxi';
  delete from centres             where tenant_id = 'machaxi';
  delete from sports              where tenant_id = 'machaxi';
  delete from applications        where tenant_id = 'machaxi';
  delete from bookings            where tenant_id = 'machaxi';
  delete from sync_jobs           where tenant_id = 'machaxi';
  delete from sync_log            where tenant_id = 'machaxi';
  -- integrations holds the Playo/Hudle venue slugs for a venue we no
  -- longer serve; leaving them risks an inbound sync_ingest matching
  delete from integrations        where tenant_id = 'machaxi';
  delete from events              where tenant_id = 'machaxi';
  delete from subscriptions       where tenant_id = 'machaxi';
  delete from tenants             where id        = 'machaxi';

  -- ------------------------------------------------------------
  -- Checks
  -- ------------------------------------------------------------
  select count(*) into v_after from members where tenant_id = 'machaxi';
  if v_after <> 0 then raise exception 'machaxi members survive: %', v_after; end if;
  if exists (select 1 from tenants where id = 'machaxi') then
    raise exception 'the machaxi tenant row survives';
  end if;

  -- the important one: prove the blast radius was zero
  select jsonb_object_agg(t, n) into v_other_after from (
    select tenant_id t, count(*) n from members     where tenant_id <> 'machaxi' group by 1
    union all
    select tenant_id, count(*) from bookings     where tenant_id <> 'machaxi' group by 1
    union all
    select tenant_id, count(*) from payments     where tenant_id <> 'machaxi' group by 1
  ) x;
  if v_other_before is distinct from v_other_after then
    raise exception 'ANOTHER TENANT MOVED. before=% after=%', v_other_before, v_other_after;
  end if;

  if (select count(*) from cross_tenant_integrity()) <> 0 then
    raise exception 'cross_tenant_integrity() is non-empty after the delete';
  end if;

  raise notice 'machaxi retired; % rows of members removed, all other tenants unchanged', v_before;
end $$;

-- The vault holds this tenant's partner credentials. They authenticate to
-- Playo/Hudle for a venue we no longer serve, so they are live keys with
-- no legitimate caller left.
do $$
declare r record;
begin
  for r in select name from vault.secrets where name like 'partner:machaxi:%' or name = 'whatsapp:machaxi'
  loop
    perform vault.delete_secret((select id from vault.secrets where name = r.name));
    raise notice 'removed vault secret %', r.name;
  end loop;
end $$;
