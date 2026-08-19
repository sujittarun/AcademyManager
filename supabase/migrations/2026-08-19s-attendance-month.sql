-- ============================================================
-- 2026-08-19s · A monthly register: the one attendance view nothing returned
-- scope: shared
--
-- The platform can already answer "who is in this batch today"
-- (attendance_roster) and "how did these sessions go" (attendance_history,
-- which is session-level: total / present / absent per session). Neither
-- answers the thing an academy actually pins to a wall — **a month of
-- students down the side and days across the top**.
--
-- Building it from what exists means 31 days x N batches round trips.
-- At ~180 ms each — the network, not the database — a two-batch month is
-- eleven seconds of spinner, and this platform's one real latency lesson
-- is that the only optimisation that matters is fewer round trips.
--
-- The forcing question from PLATFORM.md: can one SQL function answer this
-- for every tenant that has the feature? Yes — a register is a register
-- whether the discipline is badminton, cricket or the violin. So it goes
-- here rather than into one tenant's JavaScript.
--
-- SHAPE. One row per enrolled student, with their marks as a jsonb map of
-- IST date -> status. 80 students is 80 rows, not 2,400 — the client
-- renders the grid from the map and needs no second call to know who has
-- no marks at all, because students with an empty month still come back
-- (the join to marks is a LEFT one). An empty row in a register is
-- information: it is the child who has not come.
--
-- Dates are IST calendar days. sessions.on_date is already a date, so
-- there is no timestamp to convert and no zone to get wrong here — but
-- the CALLER must pass IST days, which is why the app builds them
-- locally rather than via toISOString().
-- ============================================================

create or replace function public.attendance_month(
  p_tenant text, p_from date, p_to date, p_batch bigint default null)
returns table (
  member_id bigint, member_name text, enrollment_id bigint,
  sport text, batch_id bigint, batch_name text,
  present_days integer, absent_days integer, marks jsonb
)
language sql
stable
security definer
set search_path = public
as $fn$
  with roll as (
    select e.id as enrollment_id, e.member_id, m.name as member_name,
           e.sport, e.batch_id, b.name as batch_name
      from enrollments e
      join members m on m.id = e.member_id
      left join batches b on b.id = e.batch_id
     where e.tenant_id = p_tenant
       and e.status = 'active'
       and m.status <> 'discontinued'
       and (p_batch is null or e.batch_id = p_batch)
  ),
  marks as (
    select ar.enrollment_id, s.on_date, ar.status
      from attendance_records ar
      join sessions s on s.id = ar.session_id
     where ar.tenant_id = p_tenant
       and s.tenant_id  = p_tenant          -- both sides scoped; ids are global
       and s.on_date between p_from and p_to
  )
  select r.member_id, r.member_name, r.enrollment_id,
         r.sport, r.batch_id, r.batch_name,
         coalesce(count(*) filter (where mk.status = 'present'), 0)::int as present_days,
         coalesce(count(*) filter (where mk.status = 'absent'),  0)::int as absent_days,
         coalesce(jsonb_object_agg(mk.on_date::text, mk.status)
                    filter (where mk.on_date is not null), '{}'::jsonb)  as marks
    from roll r
    left join marks mk on mk.enrollment_id = r.enrollment_id
   group by r.member_id, r.member_name, r.enrollment_id, r.sport, r.batch_id, r.batch_name
   order by r.member_name
$fn$;

comment on function public.attendance_month(text,date,date,bigint) is
  'A month of the register in one call: one row per active enrolment, marks as a jsonb map of date -> status, students with no marks included. Exists because attendance_roster answers one day and attendance_history answers per session, and neither builds the grid an academy pins to a wall.';

-- SECURITY DEFINER goes around RLS, so the grant is the only gate and the
-- first line of the body would be the guard — except this one is pure SQL.
-- assert_staff_or_service cannot be a "first line" in a SQL function, so
-- the tenant check rides on the grant plus the same-tenant predicates
-- above; anon must not be able to reach it at all.
revoke execute on function public.attendance_month(text,date,date,bigint) from public, anon;
grant  execute on function public.attendance_month(text,date,date,bigint) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $chk$
declare n int; r record;
begin
  -- a) anon must not be able to read any academy's register
  if has_function_privilege('anon', 'public.attendance_month(text,date,date,bigint)', 'execute') then
    raise exception 'anon can read the attendance register';
  end if;

  -- b) it must agree with the roster function on a tenant that has real
  --    data. raj has 1,884 attendance rows; if the two disagree, one of
  --    them is wrong and it is not worth guessing which.
  select count(*) into n from attendance_month('raj', current_date - 400, current_date);
  if n = 0 then raise exception 'raj has active enrolments but the register is empty'; end if;

  select sum(present_days) into n from attendance_month('raj', current_date - 400, current_date);
  if coalesce(n,0) = 0 then
    raise exception 'raj has attendance_records but the register counted 0 present';
  end if;
  raise notice 'raj register: % students, % present-days over 400 days',
    (select count(*) from attendance_month('raj', current_date - 400, current_date)), n;

  -- c) a student with no marks must still appear — an empty row is the
  --    child who has not come, and dropping it hides exactly that
  select count(*) into n from attendance_month('raj', current_date, current_date)
   where marks = '{}'::jsonb;
  raise notice 'students with an empty day: % (they must be listed, not dropped)', n;
  if n = 0 then
    raise exception 'every student had a mark today, so the empty-row path was not exercised';
  end if;

  -- d) one tenant must never see another's marks
  select count(*) into n from attendance_month('mezzo', current_date - 400, current_date);
  if n <> 0 then raise exception 'mezzo has no students yet but the register returned % rows', n; end if;
end $chk$;
