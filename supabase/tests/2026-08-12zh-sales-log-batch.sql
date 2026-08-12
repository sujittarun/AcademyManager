-- ============================================================
-- Behaviour test for 2026-08-12zh — sales_log_batch()
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
--
-- The claims:
--   1. It logs every lead in one call, and 'opened' still does not advance
--      the stage — the batch must not undo the draft-vs-sent distinction.
--   2. A do-not-contact lead is SKIPPED, and the rest of the batch still
--      lands. This is the whole reason it does not just raise.
--   3. It delegates to sales_log_touch(), so the arm is recorded and the
--      stage machine behaves identically to a single click.
--   4. anon and tenant staff cannot call it.
-- ============================================================

create temp table t12zh_fails (why text) on commit drop;
grant insert on t12zh_fails to anon, authenticated;

do $$
declare
  ids uuid[]; v_dnc uuid; r jsonb; n int;
begin
  -- three callable leads, plus one we will suppress
  select array_agg(id) into ids from (
    select id from sales.leads
     where phone is not null and not do_not_contact and stage = 'new'
     order by id limit 3) q;
  select id into v_dnc from sales.leads
   where phone is not null and not do_not_contact and stage = 'new'
     and not (id = any(ids)) order by id limit 1;

  if array_length(ids, 1) < 3 or v_dnc is null then
    insert into t12zh_fails values ('fixture: need 4 callable new leads');
    return;
  end if;

  perform sales_set_dnc(v_dnc, 'test');

  -- ---------- the batch ----------
  r := sales_log_batch(ids || v_dnc, 'whatsapp', 'opened', 'out',
                       'opener_batch', '8297771212');

  if (r->>'logged')::int <> 3 then
    insert into t12zh_fails values (format(
      'logged %s of 3 callable leads', r->>'logged'));
  end if;
  if (r->>'skipped')::int <> 1 then
    insert into t12zh_fails values (format(
      'skipped %s, expected 1 (the do-not-contact lead)', r->>'skipped'));
  end if;
  -- the skip must say WHY, or the operator cannot act on it
  if (r->'skipped_leads'->0->>'why') is null then
    insert into t12zh_fails values ('a skipped lead carries no reason');
  end if;

  -- ---------- a draft must still not advance the stage ----------
  select count(*) into n from sales.leads
   where id = any(ids) and stage <> 'new';
  if n > 0 then
    insert into t12zh_fails values (format(
      '%s lead(s) left ''new'' on a batch of drafts — the batch bypassed the '
      'draft-vs-sent rule', n));
  end if;
  select count(*) into n from sales.leads
   where id = any(ids) and last_touch_at is not null;
  if n > 0 then
    insert into t12zh_fails values ('a batch of drafts moved last_touch_at');
  end if;

  -- ---------- one touch each, carrying the arm ----------
  select count(*) into n from sales.touches
   where lead_id = any(ids) and outcome = 'opened';
  if n <> 3 then
    insert into t12zh_fails values (format('%s touch rows for 3 leads', n));
  end if;
  select count(*) into n from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.lead_id = any(ids) and t.variant is distinct from l.variant;
  if n > 0 then
    insert into t12zh_fails values (format(
      '%s touch(es) recorded the wrong arm', n));
  end if;
  -- and the sender must be recorded, so a restricted number is traceable
  select count(*) into n from sales.touches
   where lead_id = any(ids) and sent_from = '8297771212';
  if n <> 3 then
    insert into t12zh_fails values ('sent_from was not recorded on the batch');
  end if;

  -- ---------- and a batch of real sends DOES advance ----------
  r := sales_log_batch(ids, 'whatsapp', 'sent', 'out');
  if (r->>'logged')::int <> 3 then
    insert into t12zh_fails values ('a batch of sends did not log');
  end if;
  select count(*) into n from sales.leads
   where id = any(ids) and stage = 'contacted';
  if n <> 3 then
    insert into t12zh_fails values (format(
      'only %s of 3 advanced to contacted on a batch of real sends', n));
  end if;
end $$;

-- ------------------------------------------------------------
-- Roles
-- ------------------------------------------------------------
do $$
declare ok boolean;
begin
  set local role anon;
  ok := false;
  begin perform sales_log_batch('{}'::uuid[]); exception when others then ok := true; end;
  if not ok then insert into t12zh_fails values ('anon called sales_log_batch'); end if;
  reset role;

  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}',
    true);
  set local role authenticated;
  ok := false;
  begin perform sales_log_batch('{}'::uuid[]); exception when others then ok := true; end;
  if not ok then
    insert into t12zh_fails values ('TENANT STAFF called sales_log_batch'); end if;
  reset role;
end $$;

do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12zh_fails;
  if n > 0 then
    raise exception E'2026-08-12zh FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12zh passed: one call, drafts stay drafts, DNC skipped not fatal';
end $$;
