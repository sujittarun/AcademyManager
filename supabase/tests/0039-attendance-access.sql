-- ============================================================
-- Behaviour test for 0039 — attendance-only staff
--
-- Run inside `begin; <migration>; <this>; rollback;`.
--
-- This asks the database the only question that matters: with a real
-- coach JWT in hand, what can that coach actually reach? Reading the
-- grants would not answer it. Two platform outages were caused by SQL
-- that read correctly and behaved otherwise, so this drives the real
-- roles instead.
--
-- It collects failures rather than stopping at the first, so one run
-- reports everything that is wrong.
-- ============================================================

-- ------------------------------------------------------------
-- Setup, as the owner: coach one is assigned to DPS Miyapur only.
-- ------------------------------------------------------------
do $$
declare
  c_dps bigint; c_foreign bigint; fails text[] := '{}'; ok boolean;
begin
  select id into c_dps from centres where tenant_id = 'raj' and code = 'dps-miyapur';
  select id into c_foreign from centres where tenant_id <> 'raj' limit 1;
  if c_dps is null then raise exception 'fixture missing: raj/dps-miyapur'; end if;

  perform set_staff_scope('raj', 'coach1@rajsports.in', 'QA Coach One', ARRAY[c_dps], true);

  -- A centre belonging to another academy must be refused. This is the
  -- one place a typo could hand a coach reach into someone else's data.
  if c_foreign is not null then
    ok := false;
    begin
      perform set_staff_scope('raj', 'coach1@rajsports.in', 'QA Coach One', ARRAY[c_foreign], true);
    exception when others then ok := true; end;
    if not ok then fails := fails || ARRAY['a coach was assigned a centre from another academy']; end if;
  end if;

  -- A null in the array must not slip past the ownership test.
  ok := false;
  begin
    perform set_staff_scope('raj', 'coach1@rajsports.in', 'QA Coach One',
                            ARRAY[c_dps, null]::bigint[], true);
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['a null centre id passed the ownership check']; end if;

  -- A batch at a centre the coach is NOT assigned to, captured now,
  -- while we can still see it. Transaction-local settings carry it
  -- across the role switch below.
  declare b_theirs bigint; e_theirs bigint;
  begin
    select b.id, e.id into b_theirs, e_theirs
      from batches b
      join enrollments e on e.batch_id = b.id and e.status = 'active'
     where b.tenant_id = 'raj' and b.centre_id <> c_dps and b.active
     limit 1;
    if b_theirs is null then
      fails := fails || ARRAY['fixture: no batch at another centre to test refusal against'];
    end if;
    perform set_config('t39.b_theirs', coalesce(b_theirs::text, ''), true);
    perform set_config('t39.e_theirs', coalesce(e_theirs::text, ''), true);
    perform set_config('t39.batches',
      (select count(*)::text from batches where tenant_id = 'raj' and active), true);
  end;

  -- The scope must have survived the two refusals unchanged.
  if not exists (select 1 from staff_scopes
                  where tenant_id = 'raj' and email = 'coach1@rajsports.in'
                    and centre_ids = ARRAY[c_dps]) then
    fails := fails || ARRAY['a refused assignment still altered the stored scope'];
  end if;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% SETUP FAILURES\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

-- ------------------------------------------------------------
-- Now hold a coach's token. Everything below is what a signed-in
-- coach can really do.
-- ------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000c0ac1","email":"coach1@rajsports.in","app_metadata":{"am_role":"coach","tenant_id":"raj"}}';

do $$
declare
  fails text[] := '{}'; n int; ok boolean;
  c_dps bigint; b_mine bigint; b_theirs bigint; e_mine bigint; e_theirs bigint;
begin
  -- These lookups go through definer helpers, not the tables, because a
  -- coach cannot read batches directly (which is itself the point).
  select (my_access()->'centres'->0->>'id')::bigint into c_dps;

  if auth_role() <> 'coach' then
    fails := fails || format('role came through as "%s", not coach', auth_role());
  end if;

  -- 1. The coach sees their own centre's batches, and only those.
  select count(*) into n from my_attendance_batches('raj', ist_today());
  if n = 0 then fails := fails || ARRAY['coach sees no batches at all']; end if;
  select count(*) into n from my_attendance_batches('raj', ist_today()) q
   where q.centre_id is distinct from c_dps;
  if n > 0 then fails := fails || format('coach sees %s batches outside their centre', n); end if;

  select batch_id into b_mine from my_attendance_batches('raj', ist_today()) limit 1;

  -- 2. They can take the register at their own centre.
  select id into e_mine from enrollments
   where tenant_id = 'raj' and batch_id = b_mine and status = 'active' limit 1;
  if e_mine is not null then
    begin
      perform mark_attendance('raj', b_mine, ist_today(), e_mine, 'present', null);
    exception when others then
      fails := fails || format('coach could not mark their own centre: %s', sqlerrm);
    end;
    begin
      perform 1 from attendance_roster('raj', b_mine, ist_today());
    exception when others then
      fails := fails || format('coach could not open their own roster: %s', sqlerrm);
    end;
  end if;

  -- 3. They must be refused at a centre they are not assigned to.
  b_theirs := nullif(current_setting('t39.b_theirs', true), '')::bigint;
  e_theirs := nullif(current_setting('t39.e_theirs', true), '')::bigint;
  if b_theirs is not null then
    ok := false;
    begin perform mark_attendance('raj', b_theirs, ist_today(), e_theirs, 'present', null);
    exception when others then ok := true; end;
    if not ok then fails := fails || ARRAY['coach marked attendance at a centre they are not assigned to']; end if;

    ok := false;
    begin perform attendance_roster('raj', b_theirs, ist_today());
    exception when others then ok := true; end;
    if not ok then fails := fails || ARRAY['coach read the roster of a centre they are not assigned to']; end if;

    ok := false;
    begin perform save_attendance_session('raj', b_theirs, ist_today(), 'cancelled', '[]'::jsonb, null, 'x');
    exception when others then ok := true; end;
    if not ok then fails := fails || ARRAY['coach cancelled a session at a centre they are not assigned to']; end if;
  end if;

  -- attendance_history and attendance_dashboard take p_batch as an
  -- optional FILTER, so a per-batch guard would wave a null straight
  -- through and hand over every centre. They deliberately keep
  -- assert_staff_or_service, which a coach fails. Prove it.
  ok := false;
  begin perform 1 from attendance_history('raj', ist_today() - 30, ist_today(), null, null, null, null);
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach read attendance history across every centre']; end if;

  ok := false;
  begin perform 1 from attendance_dashboard('raj', ist_today() - 30, ist_today(), null, null, null, null);
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach read the attendance dashboard across every centre']; end if;

  -- 4. No reach into people or money through the tables. A denial here
  --    can arrive either as an error or as zero rows; both are fine,
  --    a row is not.
  declare t text; begin
    foreach t in array ARRAY['members','payments','fee_rules','reminder_events',
                             'enrollments','staff_scopes','audit_log'] loop
      begin
        execute format('select count(*) from %I', t) into n;
        if n > 0 then fails := fails || format('coach can read %s rows of %s', n, t); end if;
      exception when insufficient_privilege then null;
      end;
    end loop;
  end;

  -- 5. No reach into the money RPCs. assert_staff_or_service() must
  --    still refuse a coach; 0039 deliberately did not loosen it.
  ok := false; begin perform reminder_queue('raj');
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach could call reminder_queue and read every parent phone number']; end if;

  ok := false; begin perform tenant_health('raj');
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach could call tenant_health']; end if;

  ok := false; begin perform resolve_upi('raj', c_dps, null);
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach could read the collection account']; end if;

  ok := false; begin perform set_staff_scope('raj', 'coach1@rajsports.in', 'x', ARRAY[]::bigint[], true);
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach could edit their own centre assignment']; end if;

  ok := false;
  begin perform record_fee_payment('raj', e_mine, 100, 1, 'UPI', 'renewal');
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach could record a payment']; end if;

  -- 6. my_access() is what the app routes on, so it has to be right.
  if (my_access()->>'role') <> 'coach' then fails := fails || ARRAY['my_access reported the wrong role']; end if;
  /* KEY IS 'tenant', NOT 'tenant_id'. my_access() builds
     jsonb_build_object('tenant', auth_tenant()) — there has never been a
     tenant_id key. So this line read `NULL <> 'raj'`, which is NULL, and
     `if NULL then` is false: the check silently passed no matter which
     academy the coach belonged to. The one assertion here that proves a
     coach cannot see another academy's data proved nothing.

     Written as an explicit null test as well, so the same mistake cannot
     come back quietly — a missing key now FAILS instead of passing. */
  if (my_access()->>'tenant') is null then
    fails := fails || ARRAY['my_access returned no tenant key at all'];
  elsif (my_access()->>'tenant') <> 'raj' then
    fails := fails || ARRAY['my_access reported the wrong academy'];
  end if;
  if jsonb_array_length(my_access()->'centres') <> 1 then
    fails := fails || format('my_access listed %s centres, expected 1',
                             jsonb_array_length(my_access()->'centres'));
  end if;

  -- 7. A coach cannot reach another academy by typing its id.
  ok := false; begin perform my_attendance_batches('mpp', ist_today());
  exception when others then ok := true; end;
  if not ok then
    select count(*) into n from my_attendance_batches('mpp', ist_today());
    if n > 0 then fails := fails || ARRAY['coach saw batches at another academy by passing its id']; end if;
  end if;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% FAILURES AS COACH\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

-- ------------------------------------------------------------
-- And the part that is easy to forget: staff must be untouched.
-- A migration that locks a coach down correctly and quietly narrows
-- the manager has still broken the app.
-- ------------------------------------------------------------
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000beef","email":"staff@rajsports.in","app_metadata":{"am_role":"staff","tenant_id":"raj"}}';

do $$
declare fails text[] := '{}'; n int; n_all int; b bigint;
begin
  n_all := current_setting('t39.batches', true)::int;
  select count(*) into n from my_attendance_batches('raj', ist_today());
  if n <> n_all then
    fails := fails || format('staff sees %s of %s active batches', n, n_all);
  end if;

  select count(*) into n from members where tenant_id = 'raj';
  if n = 0 then fails := fails || ARRAY['staff lost read on members']; end if;

  select count(*) into n from reminder_queue('raj');
  select count(*) into n from staff_scopes where tenant_id = 'raj';
  if n = 0 then fails := fails || ARRAY['staff cannot see the coach list they are meant to manage']; end if;

  select id into b from batches where tenant_id = 'raj' and active limit 1;
  begin
    perform 1 from attendance_roster('raj', b, ist_today());
    perform 1 from attendance_dashboard('raj', ist_today() - 30, ist_today(), null, null, null, null);
    perform 1 from attendance_history('raj', ist_today() - 30, ist_today(), null, null, null, null);
  exception when others then
    fails := fails || format('staff lost attendance: %s', sqlerrm);
  end;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% STAFF REGRESSIONS\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

reset role;
select 'ACCESS TESTS PASSED' as result;
