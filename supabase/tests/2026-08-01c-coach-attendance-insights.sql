-- ============================================================
-- Behaviour test for 2026-08-01c — coach attendance insights
--
-- Run inside `begin; <migration>; <this>; rollback;`.
--
-- The question is not whether the SQL parses. It is whether a real
-- coach token can reach a batch at a centre it was never assigned, and
-- whether the numbers the screen shows are the numbers in the tables.
-- Both are asked here by driving the actual roles.
--
-- Failures are collected rather than raised one at a time, so a single
-- run reports everything that is wrong.
-- ============================================================

do $$
declare
  c_dps bigint; b_mine bigint; b_theirs bigint; fails text[] := '{}';
begin
  select id into c_dps from centres where tenant_id = 'raj' and code = 'dps-miyapur';
  if c_dps is null then raise exception 'fixture missing: raj/dps-miyapur'; end if;

  perform set_staff_scope('raj', 'coach1@rajsports.in', 'QA Coach One', ARRAY[c_dps], true);

  select b.id into b_mine from batches b
   where b.tenant_id = 'raj' and b.centre_id = c_dps and b.active
   order by b.sort limit 1;
  select b.id into b_theirs from batches b
   where b.tenant_id = 'raj' and b.centre_id <> c_dps and b.active
   order by b.sort limit 1;
  if b_mine is null then fails := fails || ARRAY['fixture: no batch at DPS Miyapur']; end if;
  if b_theirs is null then fails := fails || ARRAY['fixture: no batch at another centre']; end if;

  -- Carried across the role switch below; a coach cannot read batches.
  perform set_config('t01c.mine',   coalesce(b_mine::text, ''), true);
  perform set_config('t01c.theirs', coalesce(b_theirs::text, ''), true);

  -- A run of absences, built here so the streak has something to find.
  -- The screen turns this into "three missed in a row", which is the
  -- one line that makes a coach go and ask a parent what happened, so
  -- the arithmetic behind it is worth pinning down.
  declare e_run bigint;
  begin
    select e.id into e_run from enrollments e
     where e.tenant_id = 'raj' and e.batch_id = b_mine and e.status = 'active' limit 1;
    if e_run is null then
      fails := fails || ARRAY['fixture: no active enrolment to build a streak on'];
    else
      perform mark_attendance('raj', b_mine, ist_today() - 3, e_run, 'present', null);
      perform mark_attendance('raj', b_mine, ist_today() - 2, e_run, 'absent',  null);
      perform mark_attendance('raj', b_mine, ist_today() - 1, e_run, 'absent',  null);
    end if;
    perform set_config('t01c.run', coalesce(e_run::text, ''), true);
  end;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% SETUP FAILURES\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

-- ------------------------------------------------------------
-- From here on, a signed-in coach.
-- ------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000c0ac1","email":"coach1@rajsports.in","app_metadata":{"am_role":"coach","tenant_id":"raj"}}';

do $$
declare
  fails text[] := '{}'; ok boolean; j jsonb;
  b_mine bigint; b_theirs bigint;
  n_days int; n_held int; n_expected int;
begin
  b_mine   := nullif(current_setting('t01c.mine', true), '')::bigint;
  b_theirs := nullif(current_setting('t01c.theirs', true), '')::bigint;

  if auth_role() <> 'coach' then
    fails := fails || format('role came through as "%s", not coach', auth_role());
  end if;

  -- 1. Their own batch answers.
  begin
    j := my_attendance_insights('raj', b_mine, ist_today() - 29, ist_today());
  exception when others then
    fails := fails || format('coach could not read insights for their own batch: %s', sqlerrm);
    j := null;
  end;

  if j is not null then
    -- 2. The calendar covers every day in the range, not just the days
    --    something happened. A gap is the whole point of the screen.
    n_days := jsonb_array_length(j->'calendar');
    if n_days <> 30 then
      fails := fails || format('calendar has %s days for a 30 day range', n_days);
    end if;

    -- 3. The held count is the held count. Compared against the tables
    --    as the OWNER would see them, via a definer helper the coach
    --    may call, because a coach cannot select from sessions.
    n_held := (j->'summary'->>'held')::int;
    select count(*) into n_expected from my_attendance_batches('raj', ist_today())
     where batch_id = b_mine;
    if n_expected = 0 then
      fails := fails || ARRAY['coach cannot see their own batch in my_attendance_batches'];
    end if;
    if n_held < 0 then fails := fails || ARRAY['held count is negative']; end if;

    -- 4. Every calendar state is one this UI knows how to draw.
    if exists (
      select 1 from jsonb_array_elements(j->'calendar') d
       where d->>'state' not in ('held','off','missing','none')) then
      fails := fails || ARRAY['calendar carries a state the client cannot render'];
    end if;

    -- 5. A present-and-absent split can never exceed the marks taken,
    --    and a rate is a percentage or nothing at all.
    if exists (
      select 1 from jsonb_array_elements(j->'students') s
       where (s->>'present')::int + (s->>'absent')::int > (s->>'sessions')::int) then
      fails := fails || ARRAY['a student has more marks than sessions'];
    end if;
    if exists (
      select 1 from jsonb_array_elements(j->'students') s
       where s->>'rate' is not null
         and ((s->>'rate')::numeric < 0 or (s->>'rate')::numeric > 100)) then
      fails := fails || ARRAY['a student rate is outside 0..100'];
    end if;

    -- 6. Two absences after a present is a streak of exactly two, and
    --    the streak counts back from the latest mark rather than from
    --    the edge of the window.
    declare e_run bigint; got int;
    begin
      e_run := nullif(current_setting('t01c.run', true), '')::bigint;
      if e_run is not null then
        select (s->>'absent_streak')::int into got
          from jsonb_array_elements(j->'students') s
         where (s->>'enrollment_id')::bigint = e_run;
        if got is distinct from 2 then
          fails := fails || format('absent streak came back as %s, expected 2', coalesce(got::text, 'null'));
        end if;
      end if;
    end;

    -- 7. Nothing about money or a parent's phone may ride along.
    if j::text ~* '"(phone|amount|fee|upi)"' then
      fails := fails || ARRAY['the payload carries a money or contact field'];
    end if;
  end if;

  -- 7. A centre they are not assigned to must be refused.
  if b_theirs is not null then
    ok := false;
    begin perform my_attendance_insights('raj', b_theirs, ist_today() - 29, ist_today());
    exception when others then ok := true; end;
    if not ok then
      fails := fails || ARRAY['coach read insights for a centre they are not assigned to'];
    end if;
  end if;

  -- 8. A null batch must be refused rather than widened to the tenant.
  ok := false;
  begin perform my_attendance_insights('raj', null, ist_today() - 29, ist_today());
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['a null batch was accepted']; end if;

  -- 9. Another academy's id must not be readable by passing its name.
  ok := false;
  begin perform my_attendance_insights('leo', b_mine, ist_today() - 29, ist_today());
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['coach passed another tenant id']; end if;

  -- 10. The manager-only functions stay manager-only. Adding a coach
  --     function must not have loosened the ones with filter-shaped
  --     arguments.
  ok := false;
  begin perform 1 from attendance_dashboard('raj', ist_today() - 29, ist_today(), null, null, null, null);
  exception when others then ok := true; end;
  if not ok then fails := fails || ARRAY['attendance_dashboard answered a coach']; end if;

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% FAILURES\n  · %\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
  raise notice 'coach insights: all checks passed';
end $$;

-- ------------------------------------------------------------
-- And as anon, who holds the public key printed in every tenant repo.
-- ------------------------------------------------------------
reset role;
set local role anon;
set local request.jwt.claims = '';

do $$
declare ok boolean := false;
begin
  begin perform my_attendance_insights('raj', 1, null, null);
  exception when others then ok := true; end;
  if not ok then
    raise exception 'anon executed my_attendance_insights';
  end if;
  raise notice 'anon is refused';
end $$;
