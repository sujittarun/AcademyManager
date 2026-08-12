-- ============================================================
-- Behaviour test for 2026-08-12u — the sales pipeline
--
-- Run inside `begin; <migration>; <this>; rollback;` via run-test.sh.
--
-- The question this asks is not "do the grants look right". It is: with
-- a real anon key, a real tenant-staff JWT and a real coach JWT in hand,
-- can any of them reach a prospect's phone number? That is the only
-- question that matters here, because this schema holds contact details
-- for people who are not our customers.
--
-- The reason it is asked behaviourally: rls_audit() passed cleanly
-- through the worst leak this platform has had, and 0010's reasoning was
-- argued correctly and would still have published every parent's phone
-- number. A shape check cannot tell an error from data.
--
-- Failures accumulate in a temp table rather than raising at the first
-- one, so a single run reports everything that is wrong — and so they
-- survive the role switches below.
-- ============================================================

create temp table t12u_fails (why text) on commit drop;

-- The role blocks below run as anon and as authenticated, and they need to
-- be able to RECORD a failure while they are that role. Without this grant
-- a genuine leak surfaces as "permission denied for table t12u_fails"
-- instead of the assertion message that says what leaked — which is the
-- same class of mistake as a probe that asserted on len(response) and read
-- a PostgREST error body back as four rows.
grant insert on t12u_fails to anon, authenticated;

-- ------------------------------------------------------------
-- 1. Scoring and phone normalisation, as the owner.
--    norm_phone is the one function that could invent a callable-looking
--    number out of junk, so it gets tested hardest.
-- ------------------------------------------------------------
do $$
begin
  -- ten digits, +91, and 0-prefixed all normalise to the same thing
  if sales.norm_phone('9059049054')      <> '9059049054' then
    insert into t12u_fails values ('norm_phone mangled a plain 10-digit'); end if;
  if sales.norm_phone('+91 90590 49054') <> '9059049054' then
    insert into t12u_fails values ('norm_phone failed on +91 with spaces'); end if;
  if sales.norm_phone('09059049054')     <> '9059049054' then
    insert into t12u_fails values ('norm_phone failed on 0-prefix'); end if;

  -- and everything that is NOT a mobile must come back NULL, not a guess.
  -- '991219220' is a real case from the research: nine digits, and the
  -- researcher refused to pattern-complete it. The database must too.
  if sales.norm_phone('991219220') is not null then
    insert into t12u_fails values ('norm_phone accepted a 9-digit number'); end if;
  if sales.norm_phone('12345')     is not null then
    insert into t12u_fails values ('norm_phone accepted 12345'); end if;
  if sales.norm_phone('5059049054') is not null then
    insert into t12u_fails values ('norm_phone accepted a mobile starting 5'); end if;
  if sales.norm_phone('')          is not null then
    insert into t12u_fails values ('norm_phone accepted empty string'); end if;
  if sales.norm_phone(null)        is not null then
    insert into t12u_fails values ('norm_phone accepted null'); end if;
  -- a landline with an STD code is not a mobile; storing it as one would
  -- make it look callable in the console's wa.me link
  if sales.norm_phone('04023456789') is not null then
    insert into t12u_fails values ('norm_phone accepted an 11-digit landline as mobile'); end if;

  -- the score must match PLAYBOOK.md
  -- coached batches (3) + manual registration (3) + 2 branches (2)
  -- + 80 students (2) + fees published (1) + coaches named (1) = 10, capped
  if sales.lead_score(2, 80, 'Google Form only', 'monthly batches',
                      'Rs 3000/month', '4 coaches') <> 10 then
    insert into t12u_fails values ('score of an ideal lead is not 10'); end if;

  -- already has a parent portal: -3, and must not be scored as greenfield
  if sales.lead_score(1, 80, 'has parent login portal', 'monthly batches',
                      '', '') >= 5 then
    insert into t12u_fails values ('a lead with a parent portal scored too high'); end if;

  -- booking-only venue: -5, must floor at 0 not go negative
  if sales.lead_score(1, 0, '', 'court hire only', '', '') <> 0 then
    insert into t12u_fails values ('booking-only lead did not floor to 0'); end if;

  -- the generated column must agree with the function. If these can
  -- disagree, the console and a manual query disagree about who to call.
  insert into sales.leads (import_key, name, branches, students_est,
                           tech_signal, coaching_evidence, fees_seen, size_signal)
  values ('t12uideal', 'QA Ideal Academy', 2, 80, 'Google Form only',
          'monthly batches', 'Rs 3000/month', '4 coaches');
  if (select score from sales.leads where import_key = 't12uideal') <> 10 then
    insert into t12u_fails values ('generated score column disagrees with lead_score()'); end if;
end $$;

-- ------------------------------------------------------------
-- 2. Import: idempotent, and never downgrades a verified number.
-- ------------------------------------------------------------
do $$
declare v jsonb; n int;
begin
  -- first import
  v := sales_import(jsonb_build_array(jsonb_build_object(
        'name', 'QA Import Academy', 'sport', 'Cricket', 'area', 'Miyapur',
        'phone', '+91 90590 49054', 'phone_confidence', 'verified',
        'phone_source_url', 'https://example.test/contact',
        'branches', '2', 'students_est', '80',
        'tech_signal', 'Google Form only',
        'coaching_evidence', 'monthly batches')));
  if (v->>'inserted')::int <> 1 then
    insert into t12u_fails values ('first import did not insert'); end if;

  -- re-import the same academy: must update, never duplicate
  v := sales_import(jsonb_build_array(jsonb_build_object(
        'name', 'QA Import Academy', 'sport', 'Cricket',
        'phone', '9999999999', 'phone_confidence', 'directory')));
  if (v->>'updated')::int <> 1 then
    insert into t12u_fails values ('re-import did not update'); end if;

  select count(*) into n from sales.leads
   where import_key = 'qaimportacademy';
  if n <> 1 then
    insert into t12u_fails values ('re-import duplicated the lead'); end if;

  -- and it must NOT have replaced the verified number with a directory one
  if (select phone from sales.leads where import_key = 'qaimportacademy')
     <> '9059049054' then
    insert into t12u_fails values
      ('a directory number overwrote a verified one on re-import'); end if;

  -- a malformed number must be stored as malformed, not as callable
  v := sales_import(jsonb_build_array(jsonb_build_object(
        'name', 'QA Malformed', 'phone', '991219220',
        'phone_confidence', 'verified')));
  if (select phone_confidence from sales.leads where import_key = 'qamalformed')
     <> 'malformed' then
    insert into t12u_fails values
      ('a 9-digit number was not downgraded to malformed'); end if;
  if (select phone from sales.leads where import_key = 'qamalformed')
     is not null then
    insert into t12u_fails values
      ('a malformed number was stored as a phone'); end if;
end $$;

-- ------------------------------------------------------------
-- 3. Do-not-contact. The design claim is that it refuses outbound
--    touches AND survives a re-import. Both are tested, because a DNC
--    list a re-import can undo is not a DNC list.
-- ------------------------------------------------------------
do $$
declare v_lead uuid; ok boolean; v jsonb;
begin
  select id into v_lead from sales.leads where import_key = 'qaimportacademy';

  -- a normal outbound touch works and moves new -> contacted
  v := sales_log_touch(v_lead, 'whatsapp', 'sent', 'out', 'opener_cricket',
                       'hello', '8297771212');
  if v->>'stage' <> 'contacted' then
    insert into t12u_fails values ('first touch did not move stage to contacted'); end if;

  -- an inbound reply moves it to replied
  v := sales_log_touch(v_lead, 'whatsapp', 'replied', 'in');
  if v->>'stage' <> 'replied' then
    insert into t12u_fails values ('a reply did not move stage to replied'); end if;

  -- and a later outbound 'sent' must NOT drag it back to contacted
  v := sales_log_touch(v_lead, 'whatsapp', 'sent', 'out');
  if v->>'stage' <> 'replied' then
    insert into t12u_fails values ('a later send regressed the stage from replied'); end if;

  -- now suppress them
  perform sales_set_dnc(v_lead, 'asked us to stop');

  -- an outbound touch must now be refused outright
  ok := false;
  begin
    perform sales_log_touch(v_lead, 'whatsapp', 'sent', 'out');
  exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values
      ('an outbound touch to a do-not-contact lead was allowed'); end if;

  -- THE ONE THAT MATTERS: re-importing them must not un-suppress them
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Import Academy', 'phone', '9059049054',
    'phone_confidence', 'verified')));
  if not (select do_not_contact from sales.leads
           where import_key = 'qaimportacademy') then
    insert into t12u_fails values
      ('a re-import resurrected a do-not-contact lead'); end if;

  -- a fresh lead carrying a DNC number must arrive already suppressed,
  -- even under a different academy name
  perform sales_import(jsonb_build_array(jsonb_build_object(
    'name', 'QA Same Number Different Name', 'phone', '9059049054',
    'phone_confidence', 'verified')));
  if not (select do_not_contact from sales.leads
           where import_key = 'qasamenumberdifferentname') then
    insert into t12u_fails values
      ('a new lead on a DNC number was not suppressed on import'); end if;
end $$;

-- ------------------------------------------------------------
-- 4. A won lead must name the tenant it became, or the funnel cannot be
--    reconciled against operator_portfolio().
-- ------------------------------------------------------------
do $$
declare v_lead uuid; ok boolean;
begin
  select id into v_lead from sales.leads where import_key = 't12uideal';

  ok := false;
  begin
    perform sales_set_stage(v_lead, 'won');
  exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('a lead was marked won with no tenant'); end if;

  -- with a real tenant it must succeed
  begin
    perform sales_set_stage(v_lead, 'won', 'genalpha');
  exception when others then
    insert into t12u_fails values ('marking won with a real tenant failed');
  end;

  -- and a tenant that does not exist must be refused by the FK
  ok := false;
  begin
    perform sales_set_stage(v_lead, 'won', 'no-such-tenant');
  exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('a won lead accepted a non-existent tenant'); end if;
end $$;

-- ------------------------------------------------------------
-- 5. The roles. This is the part that actually protects the data, and
--    it is done by assuming each role and calling, not by reading a
--    grant. Tenant staff are `authenticated` exactly like the operator
--    is, so the grant alone cannot tell them apart — only
--    assert_operator() in each body does.
-- ------------------------------------------------------------

-- 5a. anon
do $$
declare ok boolean; n int;
begin
  -- catalogue check first
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    insert into t12u_fails values
      (format('anon holds execute on %s sales function(s)', n)); end if;

  -- then actually be anon and try
  set local role anon;
  ok := false;
  begin perform sales_leads(); exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('anon called sales_leads() successfully'); end if;

  ok := false;
  begin perform sales_pipeline(); exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('anon called sales_pipeline() successfully'); end if;

  ok := false;
  begin perform count(*) from sales.leads; exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('anon read sales.leads directly'); end if;
  reset role;
end $$;

-- 5b. tenant staff — authenticated, same as the operator
do $$
declare ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}',
    true);
  set local role authenticated;

  ok := false;
  begin perform sales_leads(); exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values
      ('TENANT STAFF READ THE PROSPECT LIST — assert_operator is not holding'); end if;

  ok := false;
  begin perform sales_pipeline(); exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('tenant staff called sales_pipeline()'); end if;

  ok := false;
  begin perform sales_import('[]'::jsonb); exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('tenant staff called sales_import()'); end if;

  ok := false;
  begin perform count(*) from sales.leads; exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('tenant staff read sales.leads directly'); end if;
  reset role;
end $$;

-- 5c. coach — the narrowest real role
do $$
declare ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"coach","tenant_id":"raj"}}',
    true);
  set local role authenticated;
  ok := false;
  begin perform sales_leads(); exception when others then ok := true; end;
  if not ok then
    insert into t12u_fails values ('a coach read the prospect list'); end if;
  reset role;
end $$;

-- 5d. the operator, who must actually be able to work
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","email":"operator@academymanager.in","app_metadata":{"am_role":"operator"}}',
    true);
  set local role authenticated;

  -- A probe that only hunts leaks reports a healthy system on the morning
  -- you have locked every real user out. So assert the paths that must
  -- KEEP working, and assert on content rather than on length.
  begin
    v := sales_pipeline();
    if (v->>'total')::int < 1 then
      insert into t12u_fails values ('operator sales_pipeline() returned no leads'); end if;
  exception when others then
    insert into t12u_fails values
      ('operator could not call sales_pipeline(): ' || sqlerrm);
  end;

  begin
    v := sales_leads();
    if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) < 1 then
      insert into t12u_fails values ('operator sales_leads() returned nothing'); end if;
    -- the row must actually carry a name, not just be a non-empty object.
    -- A PostgREST error body is a four-key object; length is not content.
    if v->0->>'name' is null then
      insert into t12u_fails values ('operator sales_leads() rows carry no name'); end if;
  exception when others then
    insert into t12u_fails values
      ('operator could not call sales_leads(): ' || sqlerrm);
  end;

  -- the wa.me link must be absent for a suppressed lead, or the console
  -- will happily offer a click-to-chat button for someone who said stop
  begin
    v := sales_leads(p_search := 'QA Import Academy');
    if v->0->>'wa_link' is not null then
      insert into t12u_fails values
        ('a do-not-contact lead still exposes a wa.me link'); end if;
  exception when others then
    insert into t12u_fails values ('wa_link check failed: ' || sqlerrm);
  end;
  reset role;
end $$;

-- ------------------------------------------------------------
-- 6. The audits must stay clean. rpc_audit() has four functions that
--    are public by design; nothing from sales may join them.
-- ------------------------------------------------------------
do $$
declare n int; extra text;
begin
  select count(*), coalesce(string_agg(fn, ', '), '') into n, extra
    from rpc_audit()
   where fn like 'sales%';
  if n > 0 then
    insert into t12u_fails values
      ('rpc_audit() reports sales functions as anon-reachable: ' || extra);
  end if;

  -- tenant_reach_audit() is the one that lists definer functions any
  -- signed-in user of any tenant can reach. Every sales function is
  -- executable by `authenticated`, so this is the audit that would catch
  -- a missing assert_operator().
  select count(*), coalesce(string_agg(fn, ', '), '') into n, extra
    from tenant_reach_audit()
   where fn like 'sales%';
  if n > 0 then
    insert into t12u_fails values
      ('tenant_reach_audit() reports sales functions unguarded: ' || extra);
  end if;
exception when undefined_function then
  -- an audit was renamed; say so rather than silently passing
  insert into t12u_fails values
    ('could not run rpc_audit()/tenant_reach_audit() — check their names');
end $$;

-- ------------------------------------------------------------
-- Report
-- ------------------------------------------------------------
do $$
declare n int; msg text;
begin
  select count(*), coalesce(string_agg('  - ' || why, E'\n'), '')
    into n, msg from t12u_fails;
  if n > 0 then
    raise exception E'2026-08-12u FAILED — % problem(s):\n%', n, msg;
  end if;
  raise notice '2026-08-12u passed: anon, tenant staff and coach are all refused; operator works; DNC survives re-import';
end $$;
