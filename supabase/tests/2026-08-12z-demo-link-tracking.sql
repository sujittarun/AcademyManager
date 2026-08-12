-- ============================================================
-- Behaviour test for 2026-08-12z — demo link tracking
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
--
-- demo_track() is deliberately anon-callable, which makes it the most
-- exposed function on the platform after the four public-by-design ones.
-- The claims that must hold:
--
--   1. anon CAN call it (or the public demo reports nothing)
--   2. anon CANNOT read back who has visited
--   3. it returns ok for an UNKNOWN ref, so it is not an enumeration oracle
--   4. it attributes a known ref to the right lead
--   5. tenant staff cannot read the activity
--   6. rpc_audit() stays empty
-- ============================================================

create temp table t12z_fails (why text) on commit drop;
grant insert on t12z_fails to anon, authenticated;

-- ------------------------------------------------------------
-- 1. ref codes: present, unique, stable
-- ------------------------------------------------------------
do $$
declare v1 text; v2 text; lid uuid; n int;
begin
  select count(*) into n from sales.leads where ref_code is null;
  if n > 0 then insert into t12z_fails values (n || ' leads have no ref_code'); end if;

  select count(*) into n from (
    select ref_code from sales.leads group by ref_code having count(*) > 1) d;
  if n > 0 then insert into t12z_fails values (n || ' duplicate ref_code(s)'); end if;

  select id, ref_code into lid, v1 from sales.leads order by id limit 1;
  select ref_code into v2 from sales.leads where id = lid;
  if v1 is distinct from v2 then
    insert into t12z_fails values ('ref_code is not stable between reads');
  end if;

  -- generated: a direct write must be refused, or a link could be
  -- reassigned to a different prospect after it was sent
  begin
    update sales.leads set ref_code = 'aaaaaaa' where id = lid;
    insert into t12z_fails values
      ('ref_code accepted a direct write — a sent link could be re-pointed');
  exception when others then null; end;
end $$;

-- ------------------------------------------------------------
-- 2. Attribution, and the enumeration guard
-- ------------------------------------------------------------
do $$
declare lid uuid; v_ref text; r jsonb; n int;
begin
  select id, ref_code into lid, v_ref from sales.leads order by id limit 1;

  r := demo_track(v_ref, 'dashboard.html', 'sess-abc', 'desktop');
  if r->>'ok' <> 'true' then
    insert into t12z_fails values ('demo_track did not return ok'); end if;

  select count(*) into n from sales.demo_visits
   where lead_id = lid and page = 'dashboard.html';
  if n <> 1 then
    insert into t12z_fails values
      (format('a known ref produced %s visit rows, expected 1', n)); end if;

  -- an UNKNOWN ref must still return ok, and must record as stray
  r := demo_track('deadbee', 'dashboard.html', 'sess-xyz', 'mobile');
  if r->>'ok' <> 'true' then
    insert into t12z_fails values
      ('demo_track revealed an unknown ref by not returning ok — this is an '
       'enumeration oracle');
  end if;
  if not exists (select 1 from sales.demo_visits
                  where ref_code = 'deadbee' and lead_id is null) then
    insert into t12z_fails values ('a stray visit was not recorded');
  end if;

  -- junk input must not raise, and must not be stored as a ref
  begin
    r := demo_track('<script>alert(1)</script>', repeat('x', 400), null, 'weird');
    if exists (select 1 from sales.demo_visits where ref_code like '%script%') then
      insert into t12z_fails values ('a non-ref-shaped value was stored as a ref_code');
    end if;
    if exists (select 1 from sales.demo_visits where length(page) > 120) then
      insert into t12z_fails values ('page was not clamped to 120 chars');
    end if;
    if exists (select 1 from sales.demo_visits where device = 'weird') then
      insert into t12z_fails values ('device accepted a value outside mobile/desktop');
    end if;
  exception when others then
    insert into t12z_fails values ('demo_track raised on junk input: ' || sqlerrm);
  end;

  -- the flood guard
  for i in 1..210 loop
    perform demo_track(v_ref, 'p' || i, 'sess-flood', 'desktop');
  end loop;
  select count(*) into n from sales.demo_visits where session_id = 'sess-flood';
  if n > 205 then
    insert into t12z_fails values
      (format('flood guard let %s rows through for one session', n));
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. The operator readback must be real, and heat must be computed
-- ------------------------------------------------------------
do $$
declare a jsonb; lid uuid; v_ref text;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);
  set local role authenticated;

  a := sales_demo_activity(30);
  if jsonb_typeof(a) <> 'array' or jsonb_array_length(a) < 1 then
    insert into t12z_fails values ('sales_demo_activity returned nothing');
  elsif a->0->>'name' is null then
    insert into t12z_fails values ('activity rows carry no lead name');
  elsif a->0->>'heat' is null then
    insert into t12z_fails values ('activity rows carry no heat');
  end if;

  -- stray traffic must be visible separately, not silently merged
  if (sales_demo_stray(30)->>'views')::int < 1 then
    insert into t12z_fails values ('stray traffic is not reported');
  end if;

  -- the per-lead link must be built and must carry the ref
  declare rows jsonb;
  begin
    rows := sales_leads(p_limit := 5);
    if rows->0->>'demo_link' is null then
      insert into t12z_fails values ('sales_leads carries no demo_link');
    elsif position(coalesce(rows->0->>'ref_code','ZZZ') in (rows->0->>'demo_link')) = 0 then
      insert into t12z_fails values ('demo_link does not contain the lead ref_code');
    end if;
  end;
  reset role;
end $$;

-- ------------------------------------------------------------
-- 4. anon: can report, cannot read
-- ------------------------------------------------------------
do $$
declare ok boolean; r jsonb;
begin
  set local role anon;

  -- must be able to report, or the public demo is silent
  begin
    r := demo_track('abc1234', 'dashboard.html', 'sess-anon', 'mobile');
    if r->>'ok' <> 'true' then
      insert into t12z_fails values ('anon could not call demo_track');
    end if;
  exception when others then
    insert into t12z_fails values ('anon was refused demo_track: ' || sqlerrm);
  end;

  -- and must NOT be able to read anything back
  ok := false;
  begin perform count(*) from sales.demo_visits; exception when others then ok := true; end;
  if not ok then
    insert into t12z_fails values ('ANON READ sales.demo_visits'); end if;

  ok := false;
  begin perform sales_demo_activity(30); exception when others then ok := true; end;
  if not ok then
    insert into t12z_fails values ('anon called sales_demo_activity'); end if;

  ok := false;
  begin perform sales_leads(); exception when others then ok := true; end;
  if not ok then
    insert into t12z_fails values ('anon called sales_leads'); end if;
  reset role;
end $$;

-- ------------------------------------------------------------
-- 5. tenant staff must not see the pipeline or the visits
-- ------------------------------------------------------------
do $$
declare ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}',
    true);
  set local role authenticated;
  ok := false;
  begin perform sales_demo_activity(30); exception when others then ok := true; end;
  if not ok then
    insert into t12z_fails values ('TENANT STAFF READ THE DEMO ACTIVITY'); end if;
  ok := false;
  begin perform count(*) from sales.demo_visits; exception when others then ok := true; end;
  if not ok then
    insert into t12z_fails values ('tenant staff read sales.demo_visits'); end if;
  reset role;
end $$;

-- ------------------------------------------------------------
-- 6. The audits
-- ------------------------------------------------------------
do $$
declare n int; extra text;
begin
  select count(*), coalesce(string_agg(fn, ', '), '') into n, extra from rpc_audit();
  if n > 0 then
    insert into t12z_fails values ('rpc_audit() is not empty: ' || extra);
  end if;
  -- demo_track must be reachable by anon (it is allowlisted, not hidden)
  if not has_function_privilege('anon',
        'public.demo_track(text,text,text,text)', 'execute') then
    insert into t12z_fails values ('demo_track lost its anon grant');
  end if;
  select count(*) into n from rls_audit();
  if n > 0 then insert into t12z_fails values (n || ' rls_audit finding(s)'); end if;
end $$;

do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12z_fails;
  if n > 0 then
    raise exception E'2026-08-12z FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12z passed: anon can report and cannot read; unknown refs leak nothing; operator sees heat';
end $$;
