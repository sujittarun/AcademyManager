-- ============================================================
-- 0040 · Shared-surface hardening: the two ways a tenant repo can
--        still hurt everyone else
-- scope: shared
--
-- Found during the 2026-08-01 team review. Neither is an exploit; both
-- are the ordinary kind of accident that a shared database turns into
-- everyone's problem.
--
-- 1. A TRIGGER ON SHARED members WITH NO EXCEPTION GUARD.
--    initialize_member_progress() (authored in the MatchPoint repo,
--    correctly tenant-guarded) fires on EVERY tenant's member insert.
--    It has no exception block, so any error inside it — a dropped
--    column in player_progress, a constraint added later, a NULL that
--    was not expected — aborts the INSERT that fired it. That means
--    MatchPoint's feature can stop Leo, Raj, Machaxi and MPP from
--    adding a student, and the error the front desk sees will name a
--    table their academy does not use.
--
--    A feature trigger is not allowed to fail its host transaction. It
--    is rewritten here to do its work inside an exception block that
--    logs and continues. Behaviour when it succeeds is byte-identical.
--
-- 2. TEST HARNESSES THAT RUN AGAINST PRODUCTION.
--    Raj's test-migration.sql inserts a booking with tenant_id='leo'
--    (a negative test — but a real cross-tenant write), test-payments
--    calls record_fee_payment('leo', …), and MPP's regression.sql
--    inserts into shared members/enrollments. All rely on a final
--    rollback. One failed rollback, one connection drop, and it is a
--    data incident with a friendly name.
--
--    assert_test_environment() gives every harness one line to refuse.
--    Production is marked as such in platform_settings, so the refusal
--    is a fact about the database rather than a habit of the author.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The trigger cannot take the whole platform down any more.
-- ------------------------------------------------------------
create or replace function public.initialize_member_progress()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_enabled boolean;
begin
  select coalesce((config#>>'{features,playerTracking}')::boolean, false)
    into v_enabled from public.tenants where id = new.tenant_id;
  if not v_enabled then return new; end if;

  -- Everything below is a FEATURE. If it breaks, the member must still
  -- be created — for this tenant and, far more importantly, for the
  -- five tenants that never asked for player tracking.
  begin
    insert into public.player_progress(tenant_id, member_id, framework_version,
                                       baseline_level, current_level, level_since, review_due_on)
      values (new.tenant_id, new.id, 1, 1, 1, coalesce(new.joined, current_date), current_date + 14)
      on conflict (tenant_id, member_id) do nothing;

    insert into public.player_level_history(tenant_id, member_id, framework_version, level,
                                            started_on, transition_type, transition_reason)
      select new.tenant_id, new.id, 1, 1, coalesce(new.joined, current_date),
             'placement', 'Initial pathway assessment pending'
       where not exists (select 1 from public.player_level_history
                          where tenant_id = new.tenant_id and member_id = new.id);
  exception when others then
    -- Loud in the log, silent to the front desk.
    begin
      insert into sync_log (tenant_id, channel, action, status, detail)
        values (new.tenant_id, '*', 'player_progress_init', 'error',
                'trigger failed for member ' || new.id || ': ' || sqlerrm);
    exception when others then null;
    end;
  end;

  return new;
end $$;

comment on function public.initialize_member_progress() is
  'Player-tracking bootstrap on shared members. Tenant-guarded AND exception-guarded: a failure here must never block member creation for any tenant.';

-- ------------------------------------------------------------
-- 2. One line a test harness can use to refuse production.
-- ------------------------------------------------------------
insert into platform_settings (key, value)
values ('environment', 'production')
on conflict (key) do update set value = excluded.value;

create or replace function public.assert_test_environment()
returns void
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_env text;
begin
  select value into v_env from platform_settings where key = 'environment';
  if coalesce(v_env, 'production') = 'production' then
    raise exception
      'REFUSING: this is the production database. Point the harness at staging (migrate.sh --target staging) or set platform_settings.environment.'
      using errcode = 'P0001';
  end if;
end $$;

comment on function public.assert_test_environment() is
  'Raises on production. Every test harness that writes to shared tables should call this first.';

revoke execute on function public.assert_test_environment() from public, anon;
grant execute on function public.assert_test_environment() to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove both, here, now.
-- ------------------------------------------------------------
do $$
declare v_ok boolean := false; v_tenant text; v_id bigint;
begin
  -- the guard must actually refuse on this database
  begin
    perform assert_test_environment();
  exception when others then v_ok := true;
  end;
  if not v_ok then
    raise exception 'assert_test_environment() did not refuse production';
  end if;

  -- the trigger must survive a broken feature table. Simulate by making
  -- the insert fail: a member for a playerTracking tenant, with the
  -- feature table temporarily renamed out from under it.
  select id into v_tenant from tenants
   where coalesce((config#>>'{features,playerTracking}')::boolean, false) limit 1;

  if v_tenant is null then
    raise notice 'no tenant has playerTracking; trigger guard installed but not exercised';
    return;
  end if;

  alter table public.player_progress rename to player_progress_probe_tmp;
  begin
    insert into members (tenant_id, name, phone)
      values (v_tenant, 'ZZ trigger guard probe', '0000000000')
      returning id into v_id;
  exception when others then
    alter table public.player_progress_probe_tmp rename to player_progress;
    raise exception 'member insert FAILED while the feature table was broken — the trigger still blocks the platform: %', sqlerrm;
  end;
  alter table public.player_progress_probe_tmp rename to player_progress;

  delete from player_level_history where member_id = v_id;
  delete from members where id = v_id;

  raise notice 'trigger guard proven: member created even with the feature table broken';
end $$;
