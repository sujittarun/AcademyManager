-- ============================================================
-- Behaviour test for 2026-08-12x — the A/B test
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
--
-- Two claims worth proving, and one hazard.
--
-- CLAIM 1: an arm cannot be reassigned. An experiment that reshuffles its
-- subjects measures nothing, so `variant` is a STORED generated column.
-- Prove that writing to it is refused, and that it survives a re-import.
--
-- CLAIM 2: a touch records the arm it was SENT under, and defaults to the
-- lead's own arm so a caller cannot log against the wrong side.
--
-- THE HAZARD: sales_log_touch gained a tenth parameter, so it is a NEW
-- function. A new function is PUBLIC-executable until revoked, and
-- revoking `anon` alone is a no-op — that is 0010, which published every
-- parent's phone number. Prove the old signature is gone and the new one
-- is closed.
-- ============================================================

create temp table t12x_fails (why text) on commit drop;
grant insert on t12x_fails to anon, authenticated;

-- ------------------------------------------------------------
-- 1. The split, and its stability
-- ------------------------------------------------------------
do $$
declare a int; b int; v1 text; v2 text; lid uuid;
begin
  select count(*) filter (where variant = 'A'),
         count(*) filter (where variant = 'B') into a, b from sales.leads;

  if a + b = 0 then
    insert into t12x_fails values ('no leads to split'); return;
  end if;
  -- an even split by construction; allow slack for small N but catch 90/10
  if (least(a, b)::numeric / (a + b)) < 0.35 then
    insert into t12x_fails values (format('lopsided split A=%s B=%s', a, b));
  end if;
  if exists (select 1 from sales.leads where variant not in ('A', 'B')) then
    insert into t12x_fails values ('a lead has a variant that is not A or B');
  end if;

  -- stable: reading it twice gives the same answer
  select id, variant into lid, v1 from sales.leads order by id limit 1;
  select variant into v2 from sales.leads where id = lid;
  if v1 is distinct from v2 then
    insert into t12x_fails values ('variant is not stable between reads');
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. The arm cannot be written, and survives a re-import
-- ------------------------------------------------------------
do $$
declare lid uuid; v_before text; v_after text; ok boolean;
begin
  select id, variant into lid, v_before from sales.leads order by id limit 1;

  -- a generated column must refuse a direct write
  ok := false;
  begin
    update sales.leads set variant = 'A' where id = lid;
  exception when others then ok := true; end;
  if not ok then
    insert into t12x_fails values
      ('variant accepted a direct write — an arm could be reassigned mid-test');
  end if;

  -- and a re-import must not move a lead between arms
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', (select name from sales.leads where id = lid),
    'phone', (select phone from sales.leads where id = lid),
    'phone_confidence', 'verified')));
  select variant into v_after from sales.leads where id = lid;
  if v_after is distinct from v_before then
    insert into t12x_fails values
      (format('a re-import moved a lead from arm %s to %s', v_before, v_after));
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. A touch records the arm, and defaults to the lead's own
-- ------------------------------------------------------------
do $$
declare lid uuid; want text; got text; v jsonb;
begin
  select id, variant into lid, want
    from sales.leads where not do_not_contact and phone is not null
    order by id limit 1;

  v := sales_log_touch(lid, 'whatsapp', 'sent', 'out', 'opener_test',
                       'hello', '8297771212');
  if v->>'variant' is distinct from want then
    insert into t12x_fails values ('sales_log_touch returned the wrong arm');
  end if;

  select variant into got from sales.touches
   where lead_id = lid order by occurred_at desc limit 1;
  if got is distinct from want then
    insert into t12x_fails values
      (format('touch stored arm %s for a lead in arm %s', got, want));
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. The results function must be honest, not merely non-empty
-- ------------------------------------------------------------
do $$
declare r jsonb;
begin
  r := sales_ab_results();

  if r->'A'->>'label' is null or r->'B'->>'label' is null then
    insert into t12x_fails values ('results are missing an arm label');
  end if;

  -- With one send it MUST say it is too early. A function that reports a
  -- winner off a single data point is worse than no function, because the
  -- number looks like an answer.
  if (r->'A'->>'sent')::int + (r->'B'->>'sent')::int < 20
     and r->>'verdict' not like 'too early%' then
    insert into t12x_fails values
      (format('claimed a verdict (%s) on %s sends', r->>'verdict',
              (r->'A'->>'sent')::int + (r->'B'->>'sent')::int));
  end if;

  -- reply rate must never exceed 100%: it would mean the denominator counts
  -- touches rather than leads
  if (r->'A'->>'reply_rate_pct')::numeric > 100
     or (r->'B'->>'reply_rate_pct')::numeric > 100 then
    insert into t12x_fails values ('a reply rate above 100% — wrong denominator');
  end if;
end $$;

-- ------------------------------------------------------------
-- 5. A chased lead is still ONE subject
-- ------------------------------------------------------------
do $$
declare lid uuid; before_sent int; after_sent int; r jsonb; arm text;
begin
  select id, variant into lid, arm
    from sales.leads where not do_not_contact and phone is not null
    order by id limit 1;

  r := sales_ab_results();
  before_sent := (r->(arm)->>'sent')::int;

  -- three more outbound touches to the SAME lead
  perform sales_log_touch(lid, 'whatsapp', 'sent', 'out');
  perform sales_log_touch(lid, 'call', 'no_answer', 'out');
  perform sales_log_touch(lid, 'whatsapp', 'sent', 'out');

  r := sales_ab_results();
  after_sent := (r->(arm)->>'sent')::int;

  if after_sent <> before_sent then
    insert into t12x_fails values
      (format('chasing one lead moved `sent` from %s to %s — the denominator '
              'counts touches, so every rate will read low',
              before_sent, after_sent));
  end if;
end $$;

-- ------------------------------------------------------------
-- 6. THE HAZARD: the old signature is gone, the new one is closed
-- ------------------------------------------------------------
do $$
declare n int; ok boolean;
begin
  -- exactly one sales_log_touch should exist
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'sales_log_touch';
  if n <> 1 then
    insert into t12x_fails values
      (format('%s overloads of sales_log_touch exist — the old signature was '
              'not dropped, and one of them may be PUBLIC-executable', n));
  end if;

  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    insert into t12x_fails values
      (format('anon holds execute on %s sales function(s) after 12x', n));
  end if;

  -- and PUBLIC, the pseudo-role that actually matters
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and array_to_string(p.proacl, ',') ~ '(^|,)=X/';
  if n > 0 then
    insert into t12x_fails values
      (format('%s sales function(s) still carry the bare =X/ PUBLIC grant', n));
  end if;

  set local role anon;
  ok := false;
  begin perform sales_ab_results(); exception when others then ok := true; end;
  if not ok then
    insert into t12x_fails values ('anon called sales_ab_results()'); end if;
  reset role;
end $$;

-- 6b. tenant staff, who are `authenticated` exactly like the operator
do $$
declare ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}',
    true);
  set local role authenticated;
  ok := false;
  begin perform sales_ab_results(); exception when others then ok := true; end;
  if not ok then
    insert into t12x_fails values
      ('TENANT STAFF READ THE A/B RESULTS'); end if;
  ok := false;
  begin perform sales_log_touch(
    (select id from sales.leads limit 1), 'whatsapp');
  exception when others then ok := true; end;
  if not ok then
    insert into t12x_fails values ('tenant staff logged a touch'); end if;
  reset role;
end $$;

-- 6c. and the operator must still be able to work
do $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);
  set local role authenticated;
  begin
    r := sales_ab_results();
    if r->>'verdict' is null then
      insert into t12x_fails values ('operator got no verdict back');
    end if;
  exception when others then
    insert into t12x_fails values
      ('operator could not call sales_ab_results(): ' || sqlerrm);
  end;
  begin
    if jsonb_typeof(sales_leads()) <> 'array' then
      insert into t12x_fails values ('operator sales_leads() broke');
    end if;
  exception when others then
    insert into t12x_fails values ('operator sales_leads() raised: ' || sqlerrm);
  end;
  reset role;
end $$;

-- 6d. do-not-contact must still refuse, after replacing the function
do $$
declare lid uuid; ok boolean;
begin
  select id into lid from sales.leads
   where phone is not null and not do_not_contact order by id limit 1;
  perform sales_set_dnc(lid, 'test');
  ok := false;
  begin perform sales_log_touch(lid, 'whatsapp', 'sent', 'out');
  exception when others then ok := true; end;
  if not ok then
    insert into t12x_fails values
      ('the new sales_log_touch ignores do-not-contact'); end if;
end $$;

-- ------------------------------------------------------------
-- Report
-- ------------------------------------------------------------
do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12x_fails;
  if n > 0 then
    raise exception E'2026-08-12x FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12x passed: arms are fixed, one lead is one subject, no verdict on thin data, anon and tenant staff refused';
end $$;
