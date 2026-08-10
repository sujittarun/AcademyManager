-- ============================================================
-- 2026-08-11y · GenAlpha's plan prices, and two rates that were totals
-- scope: shared
--
-- CORRECTION to what was written in 2026-08-11t's header. That file says
-- "the platform's fee chain has no multi-month discount". It does:
-- resolve_fee() reads fee_rules.plan_amounts, a jsonb keyed by month
-- count, and falls back to monthly * months only when the key is absent.
-- demo and raj both use it. GenAlpha's 82 rules were seeded with
-- plan_amounts = '{}', so every one of them took the linear fallback.
--
-- Consequence: resolve_fee('genalpha', months => 3) returned 10500 where
-- GenAlpha charges 9975, and 21000 for six months where they charge
-- 18900. Those two numbers are not guesses — they are the constants in
-- GenAlpha's own finalize_renewal_intake, and they are exactly
-- 3500*3*0.95 and 3500*6*0.90.
--
-- THE WORSE ONE, found while fixing the first. The merge wrote
-- student_details.coaching_fee into fee_rules.monthly_amount. For a
-- student on a monthly plan those are the same number. For a student on
-- a multi-month plan, coaching_fee is the TOTAL for the whole period, so
-- their monthly rate was stored as the full plan price:
--
--   Player G   quarterly   monthly_amount 9975   should be 3325
--   Player I         special/3m  monthly_amount 29000  should be 9666.67
--
-- reminder_queue() quotes the monthly rate. Left alone, two families
-- would have been asked for their entire quarter, every month.
--
-- Only two rules are affected: the other 80 have plan_months = 1, where
-- total and monthly are the same number and nothing is wrong.
--
-- WHAT THIS DELIBERATELY DOES NOT DO. Students on a non-standard monthly
-- rate (2000, 2750, 4250 …) get no plan_amounts. GenAlpha's own engine
-- charges a flat 9975 for any quarter regardless of the student's monthly
-- rate, which would mean quoting a 2000-a-month student MORE for three
-- months than for three single months. Rather than encode that, or invent
-- a per-student discount nobody has agreed to, those rules keep the
-- linear fallback. It is the platform's normal behaviour and it is not
-- wrong — it is just undiscounted, and it is visible here rather than
-- hidden in a number.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The academy's standard price list
-- ------------------------------------------------------------
-- Applies to the tenant default rule and to every student sitting on the
-- standard 3500 rate. Those are the students the published price list is
-- actually about.
update fee_rules fr
   set plan_amounts = jsonb_build_object('1', 3500, '3', 9975, '6', 18900)
 where fr.tenant_id = 'genalpha'
   and fr.monthly_amount = 3500
   and coalesce(fr.plan_amounts, '{}'::jsonb) = '{}'::jsonb;

-- ------------------------------------------------------------
-- 2. The two rules holding a plan total as a monthly rate
-- ------------------------------------------------------------
-- monthly becomes total/months so reminders quote a month. plan_amounts
-- keeps the exact agreed total for that plan length, so the student's own
-- price survives the division rather than being reconstructed from a
-- rounded monthly figure.
update fee_rules fr
   set monthly_amount = round(d.coaching_fee / e.plan_months, 2),
       plan_amounts   = jsonb_build_object(e.plan_months::text, d.coaching_fee)
  from members m
  join genalpha.student_details d on d.member_id = m.id
  join enrollments e on e.member_id = m.id and e.tenant_id = 'genalpha'
 where fr.tenant_id = 'genalpha'
   and fr.member_id = m.id
   and e.plan_months > 1
   and fr.monthly_amount = d.coaching_fee;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v          jsonb;
  n          int;
  v_member   bigint;
  v_before   numeric;
  v_after    numeric;
begin
  -- The academy price list, through the function a client actually calls.
  v := resolve_fee('genalpha', null, null, null, null, 1, null);
  if (v->>'amount')::numeric <> 3500 then
    raise exception '1 month resolves to %, expected 3500', v->>'amount'; end if;
  v := resolve_fee('genalpha', null, null, null, null, 3, null);
  if (v->>'amount')::numeric <> 9975 then
    raise exception '3 months resolves to %, expected 9975', v->>'amount'; end if;
  v := resolve_fee('genalpha', null, null, null, null, 6, null);
  if (v->>'amount')::numeric <> 18900 then
    raise exception '6 months resolves to %, expected 18900', v->>'amount'; end if;

  -- No rule anywhere still holds a multi-month total as a monthly rate.
  select count(*) into n
    from fee_rules fr
    join members m on m.id = fr.member_id
    join genalpha.student_details d on d.member_id = m.id
    join enrollments e on e.member_id = m.id and e.tenant_id = 'genalpha'
   where fr.tenant_id = 'genalpha' and e.plan_months > 1
     and fr.monthly_amount = d.coaching_fee;
  if n <> 0 then raise exception '% rule(s) still store a plan total as a monthly rate', n; end if;

  -- The specific family this was found on. Their quarter must still cost
  -- what they agreed, and their month must be a third of it.
  select fr.member_id into v_member
    from fee_rules fr join genalpha.student_details d on d.member_id = fr.member_id
    join enrollments e on e.member_id = fr.member_id and e.tenant_id='genalpha'
   where fr.tenant_id='genalpha' and d.fee_plan='quarterly' and e.plan_months=3
   limit 1;
  if v_member is null then raise exception 'no quarterly student found to test'; end if;

  v := resolve_fee('genalpha', v_member, null, null, null, 3, null);
  if (v->>'amount')::numeric <> 9975 then
    raise exception 'the quarterly student''s quarter now costs %, not 9975', v->>'amount'; end if;
  v := resolve_fee('genalpha', v_member, null, null, null, 1, null);
  if (v->>'amount')::numeric <> 3325 then
    raise exception 'their month resolves to %, expected 3325', v->>'amount'; end if;

  -- THE POINT OF THE WHOLE MIGRATION: what a family gets asked for.
  select sum(amount) into v_after from reminder_queue('genalpha');
  raise notice 'reminder_queue(genalpha) now totals % across % families',
    coalesce(v_after, 0), (select count(*) from reminder_queue('genalpha'));

  -- ---- NO OTHER TENANT MOVED ----
  -- fee_rules is a shared table. These are the values measured
  -- immediately before this migration; if any of them has changed, the
  -- WHERE clauses reached further than intended.
  if (resolve_fee('raj',  null,null,null,null,1,null)->>'amount')::numeric <> 1200
  or (resolve_fee('raj',  null,null,null,null,3,null)->>'amount')::numeric <> 3600
  or (resolve_fee('raj',  null,null,null,null,6,null)->>'amount')::numeric <> 7200 then
    raise exception 'raj''s fees changed';
  end if;
  if (resolve_fee('demo', null,null,null,null,1,null)->>'amount')::numeric <> 2000
  or (resolve_fee('demo', null,null,null,null,3,null)->>'amount')::numeric <> 5700
  or (resolve_fee('demo', null,null,null,null,6,null)->>'amount')::numeric <> 10800 then
    raise exception 'demo''s fees changed';
  end if;
  -- leo, machaxi, matchpoint and mpp have no fee rules; they must stay unset
  select count(*) into n from (
    select unnest(array['leo','machaxi','matchpoint','mpp']) t) x
   where (resolve_fee(x.t, null,null,null,null,1,null)->>'source') <> 'unset';
  if n <> 0 then raise exception '% tenant(s) gained a fee rule', n; end if;

  -- and no rule leaked across tenants
  select count(*) into n from fee_rules fr
    left join members m on m.id = fr.member_id
   where fr.member_id is not null and m.tenant_id is distinct from fr.tenant_id;
  if n <> 0 then raise exception '% fee rules point at another tenant''s member', n; end if;

  raise notice 'genalpha plan prices: 1m 3500, 3m 9975, 6m 18900; 2 monthly rates corrected; no other tenant moved';
end $$;
