-- ============================================================
-- Behaviour test for 2026-08-12y — the demo phone-pinning trigger
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
--
-- This trigger is attached to SHARED public.members and fires for all six
-- academies. If its tenant guard is wrong it silently overwrites real
-- families' phone numbers with the demo owner's — and nobody would notice
-- until a parent stopped getting reminders.
--
-- So the test does the only thing that settles it: inserts and updates a
-- row for a REAL tenant and asserts the phone is left alone, then does the
-- same for demo and asserts it is pinned.
-- ============================================================

create temp table t12y_fails (why text) on commit drop;

do $$
declare
  v_owner text := demo_owner_phone();
  v_raj_before text; v_raj_after text; v_id bigint;
begin
  -- ---------- a real tenant must be untouched, on INSERT ----------
  insert into members (tenant_id, name, phone, parent_phone, status)
  values ('raj', 'QA Trigger Probe', '9876500011', '9876500012', 'active')
  returning id, phone into v_id, v_raj_after;

  if v_raj_after <> '9876500011' then
    insert into t12y_fails values (format(
      'INSERT for tenant raj had its phone rewritten to %s — the trigger '
      'guard is not holding and real families are affected', v_raj_after));
  end if;
  if (select parent_phone from members where id = v_id) <> '9876500012' then
    insert into t12y_fails values
      ('INSERT for tenant raj had parent_phone rewritten');
  end if;

  -- ---------- and on UPDATE ----------
  update members set phone = '9876500099' where id = v_id;
  select phone into v_raj_after from members where id = v_id;
  if v_raj_after <> '9876500099' then
    insert into t12y_fails values (format(
      'UPDATE for tenant raj was rewritten to %s', v_raj_after));
  end if;

  -- ---------- demo must be pinned, whatever is written ----------
  insert into members (tenant_id, name, phone, parent_phone, status)
  values ('demo', 'QA Demo Probe', '9000000999', '9000000998', 'active')
  returning id into v_id;

  if (select phone from members where id = v_id) <> v_owner then
    insert into t12y_fails values
      ('a new demo member kept its seeded phone instead of the owner''s');
  end if;
  if (select parent_phone from members where id = v_id) <> v_owner then
    insert into t12y_fails values
      ('a new demo member kept its seeded parent_phone');
  end if;

  -- an explicit attempt to change it back must not stick
  update members set phone = '9123456780' where id = v_id;
  if (select phone from members where id = v_id) <> v_owner then
    insert into t12y_fails values
      ('a demo phone was successfully changed away from the owner''s number');
  end if;

  -- ---------- the whole existing roster ----------
  if exists (select 1 from members where tenant_id = 'demo'
              and (coalesce(phone,'') <> v_owner
                or coalesce(parent_phone,'') <> v_owner)) then
    insert into t12y_fails values ('some existing demo rows were not backfilled');
  end if;

  -- ---------- nothing outside demo carries the owner number ----------
  if exists (select 1 from members
              where tenant_id <> 'demo' and phone = v_owner) then
    insert into t12y_fails values
      ('the owner number leaked onto a non-demo tenant''s member');
  end if;
  if exists (select 1 from coaches
              where tenant_id <> 'demo' and phone = v_owner) then
    insert into t12y_fails values
      ('the owner number leaked onto a non-demo tenant''s coach');
  end if;
end $$;

-- ---------- a rebuild must not revert the phones ----------
-- This is the whole reason the change is a trigger and not an UPDATE.
do $$
declare n int;
begin
  perform public.demo_reset('rebuild');
  select count(*) into n from members
   where tenant_id = 'demo'
     and (coalesce(phone,'') <> demo_owner_phone()
       or coalesce(parent_phone,'') <> demo_owner_phone());
  if n > 0 then
    insert into t12y_fails values (format(
      'demo_reset(rebuild) reverted %s phone(s) — the trigger did not fire '
      'on the seed insert, so the change is not durable', n));
  end if;
exception when others then
  -- demo_reset may be heavy or unavailable in a test transaction; say so
  -- rather than passing quietly on an untested claim
  insert into t12y_fails values
    ('could not exercise demo_reset(rebuild): ' || sqlerrm);
end $$;

-- ---------- branding ----------
do $$
begin
  if (select name from tenants where id = 'demo') <> 'Sports Academy' then
    insert into t12y_fails values ('demo tenant is not named Sports Academy');
  end if;
  if exists (select 1 from centres where tenant_id = 'demo'
              and name like '%Crescent%') then
    insert into t12y_fails values ('a demo centre still says Crescent');
  end if;
  -- and no OTHER tenant was renamed by a stray replace()
  if exists (select 1 from tenants where id <> 'demo'
              and name = 'Sports Academy') then
    insert into t12y_fails values
      ('another tenant was renamed to Sports Academy');
  end if;
end $$;

do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12y_fails;
  if n > 0 then
    raise exception E'2026-08-12y FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12y passed: demo pinned to the owner number, other tenants untouched, survives a rebuild';
end $$;
