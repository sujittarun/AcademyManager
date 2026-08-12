-- ============================================================
-- Behaviour test for 2026-08-12za — demo_snapshot()
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
--
-- This is an anon-callable SECURITY DEFINER function that borrows a staff
-- identity. Three things have to hold, and none of them is provable by
-- reading the SQL:
--
--   1. It returns the DEMO tenant's real numbers — to anyone, from any
--      identity. A raj staff member calling it must get demo's figures,
--      not raj's, because there is no argument to influence it.
--   2. The payload carries no personal data.
--   3. The borrowed jwt claim does not survive the call — otherwise every
--      statement after it in the same request runs as staff-of-demo.
-- ============================================================

create temp table t12za_fails (why text) on commit drop;
grant insert on t12za_fails to anon, authenticated;

-- ------------------------------------------------------------
-- 1. Structural: no arguments means nothing to point elsewhere
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'demo_snapshot'
     and pg_get_function_identity_arguments(p.oid) = '';
  if n <> 1 then
    insert into t12za_fails values
      ('demo_snapshot does not have exactly one zero-argument signature — a '
       'parameter would make the tenant caller-chosen, which is the 0009/0010 bug');
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. As the owner: the numbers must be real, not the seed's 16
-- ------------------------------------------------------------
do $$
declare s jsonb; v_real_members int; v_real_dues int;
begin
  s := demo_snapshot();

  select count(*) into v_real_members from members
   where tenant_id = 'demo'
     and coalesce(status,'active') not in ('discontinued','inactive');

  if (s->>'active_members')::int <> v_real_members then
    insert into t12za_fails values (format(
      'snapshot says %s active members, the table says %s',
      s->>'active_members', v_real_members));
  end if;
  if (s->>'active_members')::int <= 16 then
    insert into t12za_fails values
      ('active_members is <= 16 — it is still reading the JS seed, not Postgres');
  end if;

  -- dues must come from reminder_queue, so they must MATCH reminder_queue
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"demo"}}',
    true);
  select count(*) into v_real_dues from reminder_queue('demo', current_date);
  perform set_config('request.jwt.claims', '', true);

  if (s->>'dues_count')::int <> v_real_dues then
    insert into t12za_fails values (format(
      'snapshot dues_count %s does not match reminder_queue %s — the demo is '
      'computing dues somewhere else', s->>'dues_count', v_real_dues));
  end if;

  -- a flat-rate multiple is the bug this replaces: dues_amount must NOT be
  -- dues_count times a single plan price
  if (s->>'dues_count')::int > 1
     and (s->>'dues_amount')::numeric =
         (s->>'dues_count')::numeric * 3500 then
    insert into t12za_fails values
      ('dues_amount is exactly count x 3500 — that is the flat-rate JS bug');
  end if;

  -- the revenue series must be present and shaped for the chart
  if jsonb_typeof(s->'revenue_months') <> 'array'
     or jsonb_array_length(s->'revenue_months') = 0 then
    insert into t12za_fails values ('revenue_months is empty');
  elsif (s->'revenue_months'->0->>'m') is null
     or (s->'revenue_months'->0->>'v') is null then
    insert into t12za_fails values ('revenue_months rows lack m/v keys');
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. No personal data in the payload, checked against real rows
-- ------------------------------------------------------------
do $$
declare s jsonb; v_name text; v_phone text;
begin
  s := demo_snapshot();

  if s::text ~* '"(name|phone|parent_name|parent_phone|member_name)"\s*:' then
    insert into t12za_fails values ('payload carries a personal-data key');
  end if;

  -- and no actual value from the roster
  select name, phone into v_name, v_phone from members
   where tenant_id = 'demo' limit 1;
  if v_name is not null and position(v_name in s::text) > 0 then
    insert into t12za_fails values ('a real demo member name is in the payload');
  end if;
  if v_phone is not null and position(v_phone in s::text) > 0 then
    insert into t12za_fails values ('a demo phone number is in the payload');
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. The borrowed identity must not survive
-- ------------------------------------------------------------
do $$
declare s jsonb; v_after text;
begin
  perform set_config('request.jwt.claims', '', true);
  s := demo_snapshot();
  v_after := coalesce(current_setting('request.jwt.claims', true), '');
  if v_after ~ 'am_role' then
    insert into t12za_fails values (format(
      'demo_snapshot left claims behind: %s — every later statement in the '
      'same request would run as staff-of-demo', left(v_after, 60)));
  end if;

  -- and a pre-existing identity must be restored, not blanked
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);
  s := demo_snapshot();
  if coalesce(current_setting('request.jwt.claims', true), '') !~ 'operator' then
    insert into t12za_fails values
      ('demo_snapshot destroyed the caller''s original claims instead of restoring them');
  end if;
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ------------------------------------------------------------
-- 5. Another tenant's staff gets DEMO's numbers, and none of their own
-- ------------------------------------------------------------
do $$
declare s jsonb; v_demo int; v_raj int;
begin
  select count(*) into v_demo from members where tenant_id = 'demo'
     and coalesce(status,'active') not in ('discontinued','inactive');
  select count(*) into v_raj  from members where tenant_id = 'raj'
     and coalesce(status,'active') not in ('discontinued','inactive');

  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}',
    true);
  set local role authenticated;
  begin
    s := demo_snapshot();
    if (s->>'active_members')::int = v_raj and v_raj <> v_demo then
      insert into t12za_fails values
        ('a raj staff member got RAJ''s numbers from demo_snapshot — the tenant '
         'is not hard-coded');
    end if;
    if (s->>'active_members')::int <> v_demo then
      insert into t12za_fails values
        ('demo_snapshot returned something other than demo''s roster to raj staff');
    end if;
  exception when others then
    insert into t12za_fails values
      ('raj staff could not call demo_snapshot: ' || sqlerrm);
  end;
  reset role;
end $$;

-- ------------------------------------------------------------
-- 6. anon must be able to call it — the public demo depends on it
-- ------------------------------------------------------------
do $$
declare s jsonb; ok boolean;
begin
  set local role anon;
  begin
    s := demo_snapshot();
    if (s->>'active_members')::int <= 16 then
      insert into t12za_fails values
        ('anon got the seed numbers, not the real roster');
    end if;
    if s->>'source' <> 'postgres' then
      insert into t12za_fails values ('anon payload is not marked as coming from postgres');
    end if;
  exception when others then
    insert into t12za_fails values
      ('ANON CANNOT CALL demo_snapshot — the public demo would be blank: ' || sqlerrm);
  end;

  -- but anon still must not reach the tables it reads
  ok := false;
  begin perform count(*) from members where tenant_id = 'demo';
  exception when others then ok := true; end;
  if not ok and (select count(*) from members where tenant_id = 'demo') > 0 then
    insert into t12za_fails values ('anon read the members table directly');
  end if;
  reset role;
end $$;

-- ------------------------------------------------------------
-- 7. Audits stay clean
-- ------------------------------------------------------------
do $$
declare n int; extra text;
begin
  select count(*), coalesce(string_agg(fn, ', '), '') into n, extra from rpc_audit();
  if n > 0 then
    insert into t12za_fails values ('rpc_audit() is not empty: ' || extra);
  end if;
  select count(*) into n from rls_audit();
  if n > 0 then insert into t12za_fails values (n || ' rls_audit finding(s)'); end if;
end $$;

do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12za_fails;
  if n > 0 then
    raise exception E'2026-08-12za FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12za passed: real Postgres numbers to anyone, demo only, no PII, no leaked identity';
end $$;
