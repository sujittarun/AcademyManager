-- ============================================================
-- Behaviour test for 2026-09-03a — a corrected joining date and members.joined
--
-- Run inside `begin; <migration>; <this>; rollback;`.
--
-- The migration proves itself against one real student. This proves the
-- rule against the shapes that student does not have: a fee already taken,
-- and a member holding two enrolments. The second is the one that can do
-- damage — writing members.joined there would overwrite a date that belongs
-- to the OTHER enrolment, and nothing on screen would say so.
-- ============================================================
do $$
declare
  c bigint; m bigint; e1 bigint; e2 bigint;
  j date; r date; mj date; res jsonb; fails text[] := '{}';
begin
  select id into c from centres where tenant_id='genalpha' limit 1;
  if c is null then raise exception 'fixture missing: a genalpha centre'; end if;

  -- ----------------------------------------------------------
  -- G1 · one enrolment, nothing paid: biography and cycle both move,
  --      and the member row moves with them. This is G. Ramchandan's case.
  -- ----------------------------------------------------------
  insert into members (tenant_id,name,status,joined) values ('genalpha','ZZ G1','active','2026-08-02')
    returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('genalpha',m,c,'Cricket',1,'2026-08-02','2026-08-02','active') returning id into e1;

  res := set_joining_date('genalpha', e1, '2026-09-02');
  select joined_on, renewal_on into j, r from enrollments where id=e1;
  select joined into mj from members where id=m;

  if (j,r,mj) is distinct from (date '2026-09-02', date '2026-09-02', date '2026-09-02') then
    fails := fails || format('G1 joined_on=%s renewal_on=%s members.joined=%s — all three should be 2026-09-02', j, r, mj);
  end if;
  if not (res->>'member_joined_moved')::boolean then
    fails := fails || 'G1 the return did not report the member row moving'::text;
  end if;

  -- ----------------------------------------------------------
  -- G2 · a fee has landed: the joining day is biography now. members.joined
  --      still follows it; renewal_on must not budge, or the family is re-billed.
  -- ----------------------------------------------------------
  perform record_fee_payment('genalpha', e1, 3500, 1, 'UPI', 'renewal', '2026-09-02');
  select renewal_on into r from enrollments where id=e1;

  res := set_joining_date('genalpha', e1, '2026-07-15');
  select joined_on into j from enrollments where id=e1;
  select joined into mj from members where id=m;

  if j <> date '2026-07-15' then
    fails := fails || format('G2 the joining day did not move: %s', j);
  end if;
  if mj <> date '2026-07-15' then
    fails := fails || format('G2 members.joined did not follow: %s — the app would show the old date', mj);
  end if;
  if (select renewal_on from enrollments where id=e1) <> r then
    fails := fails || format('G2 a paid cycle was moved: %s -> %s',
                             r, (select renewal_on from enrollments where id=e1));
  end if;
  if (res->>'fees_taken')::int <> 1 then
    fails := fails || format('G2 fees_taken=%s', res->>'fees_taken');
  end if;

  -- ----------------------------------------------------------
  -- G3 · two enrolments, one member: members.joined has no single answer,
  --      so it must be left exactly as it is while the named enrolment moves.
  -- ----------------------------------------------------------
  insert into members (tenant_id,name,status,joined) values ('genalpha','ZZ G3','active','2026-03-01')
    returning id into m;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('genalpha',m,c,'Cricket',1,'2026-03-01','2026-03-01','active') returning id into e1;
  insert into enrollments (tenant_id,member_id,centre_id,sport,plan_months,joined_on,renewal_on,status)
    values ('genalpha',m,c,'Fitness',1,'2026-06-01','2026-06-01','active') returning id into e2;

  res := set_joining_date('genalpha', e2, '2026-05-20');
  select joined into mj from members where id=m;
  select joined_on into j from enrollments where id=e2;

  if mj <> date '2026-03-01' then
    fails := fails || format('G3 members.joined was overwritten to %s — it belongs to the other enrolment', mj);
  end if;
  if j <> date '2026-05-20' then
    fails := fails || format('G3 the named enrolment did not move: %s', j);
  end if;
  if (select joined_on from enrollments where id=e1) <> date '2026-03-01' then
    fails := fails || 'G3 the OTHER enrolment moved'::text;
  end if;
  if (res->>'member_joined_moved')::boolean then
    fails := fails || 'G3 the return claimed the member row moved'::text;
  end if;

  -- ----------------------------------------------------------
  -- G4 · the guards 2026-08-24f shipped still hold.
  -- ----------------------------------------------------------
  begin perform set_joining_date('genalpha', e2, '2099-01-01');
        fails := fails || 'G4 a future joining date was accepted'::text;
  exception when check_violation then null; end;

  begin perform set_joining_date('genalpha', e2, null);
        fails := fails || 'G4 a null joining date was accepted'::text;
  exception when check_violation then null; end;

  begin perform set_joining_date('mezzo', e2, '2026-05-01');
        fails := fails || 'G4 cross-tenant reach: a genalpha enrolment moved under mezzo'::text;
  exception when no_data_found then null; end;

  -- G5 · and the cross-tenant guard must not have moved anything on its way out.
  if (select joined_on from enrollments where id=e2) <> date '2026-05-20' then
    fails := fails || 'G5 a refused call still wrote'::text;
  end if;

  if array_length(fails,1) > 0 then
    raise exception E'joining-date member-row test FAILED:\n  - %', array_to_string(fails, E'\n  - ');
  end if;
  raise notice 'joining-date member-row blocks passed (G1-G5)';
end $$;
