-- ============================================================
-- Behaviour test for 2026-08-12v — alternate numbers
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
-- 2026-08-12u is already applied, so this proves only what 12v adds.
--
-- The migration header makes one non-obvious claim: a stop request on ANY
-- of a lead's numbers suppresses that lead, and every other lead
-- reachable on the same number. That is the whole reason alt_phones is a
-- column rather than a line in notes, so it is the thing to prove.
-- ============================================================

create temp table t12v_fails (why text) on commit drop;
grant insert on t12v_fails to anon, authenticated;

-- ------------------------------------------------------------
-- 1. Import carries alternates, normalises them, and drops junk.
-- ------------------------------------------------------------
do $$
declare v jsonb; v_alts text[];
begin
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Splash In', 'sport', 'Swimming', 'area', 'Beeramguda',
    'phone', '8297972929',
    -- as published: a second mobile, a +91 form, a duplicate of the
    -- primary, and one unusable value
    'alt_phones', jsonb_build_array('9912122250', '+91 90590 49054',
                                    '8297972929', '991219220'),
    'phone_confidence', 'verified',
    'coaching_evidence', 'monthly batches',
    'tech_signal', 'no online booking')));

  select alt_phones into v_alts from sales.leads
   where import_key = 'qasplashin';

  if not ('9912122250' = any(v_alts)) then
    insert into t12v_fails values ('a second mobile was not stored'); end if;
  if not ('9059049054' = any(v_alts)) then
    insert into t12v_fails values ('a +91-form alternate was not normalised'); end if;
  if '8297972929' = any(v_alts) then
    insert into t12v_fails values ('the primary was duplicated into alt_phones'); end if;
  -- 991219220 is nine digits. It must be dropped, not completed.
  if exists (select 1 from unnest(v_alts) a where a like '99121922%') then
    insert into t12v_fails values ('a 9-digit alternate was stored as callable'); end if;
end $$;

-- ------------------------------------------------------------
-- 2. THE CLAIM: stop on an alternate suppresses the lead, and any other
--    lead reachable on that number.
-- ------------------------------------------------------------
do $$
declare v_lead uuid; v_other uuid; v jsonb; ok boolean;
begin
  -- a second academy whose PRIMARY is the first academy's ALTERNATE.
  -- This is the Greenlands / Suresh Krishna case from the research: one
  -- operator, two names, one number.
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Second Site', 'phone', '9912122250',
    'phone_confidence', 'verified',
    'coaching_evidence', 'monthly batches')));

  select id into v_lead  from sales.leads where import_key = 'qasplashin';
  select id into v_other from sales.leads where import_key = 'qasecondsite';

  -- stop request arrives against the FIRST lead
  v := sales_set_dnc(v_lead, 'asked us to stop');

  if not (select do_not_contact from sales.leads where id = v_lead) then
    insert into t12v_fails values ('the lead itself was not suppressed'); end if;

  -- the other academy shares 9912122250, so it must be suppressed too
  if not (select do_not_contact from sales.leads where id = v_other) then
    insert into t12v_fails values
      ('a lead sharing an alternate number was left reachable — the DNC has a gap');
  end if;

  -- every one of the numbers must be on the list, not just the primary
  if not exists (select 1 from sales.dnc where phone = '9912122250') then
    insert into t12v_fails values
      ('an alternate number was not written to sales.dnc'); end if;
  if not exists (select 1 from sales.dnc where phone = '8297972929') then
    insert into t12v_fails values
      ('the primary number was not written to sales.dnc'); end if;
  if not exists (select 1 from sales.dnc where phone = '9059049054') then
    insert into t12v_fails values
      ('a second alternate was not written to sales.dnc'); end if;

  -- outbound is refused on both
  ok := false;
  begin perform sales_log_touch(v_other, 'whatsapp', 'sent', 'out');
  exception when others then ok := true; end;
  if not ok then
    insert into t12v_fails values
      ('an outbound touch to the shared-number lead was allowed'); end if;

  -- and a re-import on ANY of those numbers must arrive suppressed
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Third Name Same Operator', 'phone', '9059049054',
    'phone_confidence', 'verified')));
  if not (select do_not_contact from sales.leads
           where import_key = 'qathirdnamesameoperator') then
    insert into t12v_fails values
      ('a new lead on a DNC alternate was not suppressed on import'); end if;

  -- the console must not offer a click-to-chat for any of them
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);
  v := sales_leads(p_search := 'QA Second Site');
  if v->0->>'wa_link' is not null then
    insert into t12v_fails values
      ('a suppressed lead still exposes a wa.me link'); end if;
end $$;

-- ------------------------------------------------------------
-- 3. Re-import must union alternates, not drop the ones already known.
-- ------------------------------------------------------------
do $$
declare v_alts text[];
begin
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Union Test', 'phone', '9000000001',
    'alt_phones', jsonb_build_array('9000000002'),
    'phone_confidence', 'verified')));
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Union Test', 'phone', '9000000001',
    'alt_phones', jsonb_build_array('9000000003'),
    'phone_confidence', 'verified')));

  select alt_phones into v_alts from sales.leads
   where import_key = 'qauniontest';
  if not ('9000000002' = any(v_alts) and '9000000003' = any(v_alts)) then
    insert into t12v_fails values
      (format('re-import lost an alternate; have %s', v_alts)); end if;
end $$;

-- ------------------------------------------------------------
-- 4. The lockdown still holds after replacing three functions.
--    `create or replace` preserves ACLs, but a changed signature would
--    silently restore the default PUBLIC grant — the 0010 lesson.
-- ------------------------------------------------------------
do $$
declare ok boolean; n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    insert into t12v_fails values
      (format('anon holds execute on %s sales function(s) after 12v', n)); end if;

  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}',
    true);
  set local role authenticated;
  ok := false;
  begin perform sales_leads(); exception when others then ok := true; end;
  if not ok then
    insert into t12v_fails values
      ('TENANT STAFF READ THE PROSPECT LIST after 12v'); end if;
  ok := false;
  begin perform sales_import('[]'::jsonb); exception when others then ok := true; end;
  if not ok then
    insert into t12v_fails values ('tenant staff called sales_import() after 12v'); end if;
  reset role;
end $$;

-- ------------------------------------------------------------
-- Report
-- ------------------------------------------------------------
do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12v_fails;
  if n > 0 then
    raise exception E'2026-08-12v FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12v passed: a stop on any number suppresses every lead reachable on it';
end $$;
