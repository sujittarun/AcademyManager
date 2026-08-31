-- The five real shapes a fee arrives in, driven through record_fee_payment
-- itself. Rolled back by run-test.sh.

do $$
declare
  v_member bigint; v_enroll bigint; v_centre bigint; v_res jsonb;
begin
  select id into v_centre from centres where tenant_id = 'genalpha' order by id limit 1;

  -- ---------- 1. LATE: due the 21st, pays the 31st ----------
  insert into members (tenant_id, name, status, program)
  values ('genalpha', 'ZZ Late Probe', 'active', 'cricket') returning id into v_member;
  insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                           joined_on, renewal_on, status)
  values ('genalpha', v_member, v_centre, 'cricket', 1,
          '2026-06-21', '2026-08-21', 'active') returning id into v_enroll;
  -- A prior fee so this is not treated as the first one.
  insert into payments (tenant_id, name, type, amount, on_date, enrollment_id, member_id,
                        centre_id, sport, months, period_from, period_to, kind, status)
  values ('genalpha','ZZ Late Probe','Coaching',3500,'2026-07-21',v_enroll,v_member,
          v_centre,'cricket',1,'2026-07-21','2026-08-21','renewal','paid');

  v_res := record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal', date '2026-08-31');
  if (v_res->>'period_from')::date <> date '2026-08-21' then
    raise exception '1. late payment starts %, expected 2026-08-21 — the anniversary moved',
      v_res->>'period_from';
  end if;
  if (v_res->>'period_to')::date <> date '2026-09-21' then
    raise exception '1. late payment ends %, expected 2026-09-21', v_res->>'period_to';
  end if;

  -- ---------- 2. EARLY: due the 21st, pays the 15th ----------
  update enrollments set renewal_on = '2026-10-21' where id = v_enroll;
  v_res := record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal', date '2026-10-15');
  if (v_res->>'period_from')::date <> date '2026-10-21' then
    raise exception '2. early payment starts %, expected 2026-10-21 — days were lost',
      v_res->>'period_from';
  end if;

  -- ---------- 3. VERY OVERDUE: three months behind, pays one ----------
  -- One month bought is one month of coverage. They stay behind, which is the
  -- arithmetic of a subscription and the point of the rule.
  update enrollments set renewal_on = '2026-06-21' where id = v_enroll;
  v_res := record_fee_payment('genalpha', v_enroll, 3500, 1, 'UPI', 'renewal', date '2026-09-15');
  if (v_res->>'period_from')::date <> date '2026-06-21' then
    raise exception '3. overdue payment starts %, expected 2026-06-21', v_res->>'period_from';
  end if;
  if (v_res->>'period_to')::date <> date '2026-07-21' then
    raise exception '3. overdue payment ends %, expected 2026-07-21 — one month buys one month',
      v_res->>'period_to';
  end if;

  -- ---------- 4. REJOIN: back on the 17th, settles on the 20th ----------
  declare v_m2 bigint; v_e2 bigint;
  begin
    insert into members (tenant_id, name, status, program, rejoined_at)
    values ('genalpha', 'ZZ Rejoin Fee Probe', 'active', 'cricket', '2026-08-17')
    returning id into v_m2;
    insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                             joined_on, renewal_on, status)
    values ('genalpha', v_m2, v_centre, 'cricket', 1,
            '2026-01-10', '2026-08-17', 'active') returning id into v_e2;
    insert into payments (tenant_id, name, type, amount, on_date, enrollment_id, member_id,
                          centre_id, sport, months, period_from, period_to, kind, status)
    values ('genalpha','ZZ Rejoin Fee Probe','Coaching',3500,'2026-02-10',v_e2,v_m2,
            v_centre,'cricket',1,'2026-01-10','2026-02-10','renewal','paid');

    v_res := record_fee_payment('genalpha', v_e2, 3500, 1, 'UPI', 'renewal', date '2026-08-20');
    if (v_res->>'period_from')::date <> date '2026-08-17' then
      raise exception '4. rejoin fee starts %, expected the rejoin date 2026-08-17',
        v_res->>'period_from';
    end if;
  end;

  -- ---------- 5. FIRST FEE EVER: anchors to its own payment date ----------
  -- joined_on is when the owner typed them in, which for a player who has been
  -- coming for months is not when their cycle starts.
  declare v_m3 bigint; v_e3 bigint;
  begin
    insert into members (tenant_id, name, status, program)
    values ('genalpha', 'ZZ First Fee Probe', 'active', 'cricket') returning id into v_m3;
    insert into enrollments (tenant_id, member_id, centre_id, sport, plan_months,
                             joined_on, renewal_on, status)
    values ('genalpha', v_m3, v_centre, 'cricket', 1,
            '2026-08-24', '2026-08-24', 'active') returning id into v_e3;

    v_res := record_fee_payment('genalpha', v_e3, 3500, 1, 'UPI', 'renewal', date '2026-08-20');
    if (v_res->>'period_from')::date <> date '2026-08-20' then
      raise exception '5. first fee starts %, expected its own pay date 2026-08-20',
        v_res->>'period_from';
    end if;
  end;

  raise notice 'OK: late, early, very overdue, rejoin and first-fee all hold';
end $$;
