-- ============================================================
-- 2026-08-01c — what a coach may see about their own batch
--
-- 0039 gave a coach the register and nothing else. A register answers
-- "who is in front of me right now" and none of the questions a coach
-- actually carries between sessions:
--
--   · did I forget to take a register last Thursday?
--   · is this batch thinning out, or was last week one bad day?
--   · which child has quietly stopped turning up?
--
-- attendance_history() and attendance_dashboard() answer those for a
-- manager and deliberately keep the staff guard, because their p_batch
-- is an optional FILTER: a per-batch check would wave a null straight
-- through and hand a coach every centre in the academy. So this is a
-- separate function whose p_batch is a TARGET — required, and checked
-- before anything is read. That is the shape rule 0039 set down, and
-- this is the second function to follow it.
--
-- Money and phone numbers do not appear here, the same as the roster.
-- Generic on purpose: any academy running batches wants this, so it is
-- not gated on a module and carries no tenant name.
-- ============================================================

create or replace function my_attendance_insights(
  p_tenant text,
  p_batch  bigint,
  p_from   date default null,
  p_to     date default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_to    date := coalesce(p_to, ist_today());
  v_from  date := coalesce(p_from, (coalesce(p_to, ist_today()) - interval '29 days')::date);
  v_today date := ist_today();
  v_days  int[];
  v_first date;
  v_out   jsonb;
begin
  -- A null batch must be refused before the guard, not by it. For a
  -- coach assert_attendance_access() would fail the batch lookup and
  -- raise anyway, but staff pass that guard early, and a null target
  -- would then quietly widen the query to the whole tenant.
  if p_batch is null then
    raise exception 'A batch is required.' using errcode = 'check_violation';
  end if;
  perform assert_attendance_access(p_tenant, p_batch);

  if v_from > v_to then
    raise exception 'The start date is after the end date.' using errcode = 'check_violation';
  end if;
  -- A coach scrolling back a year would ask the database to build a
  -- calendar nobody reads. A season is plenty.
  if v_to - v_from > 400 then
    raise exception 'That range is too long.' using errcode = 'check_violation';
  end if;

  select b.days into v_days
    from batches b where b.id = p_batch and b.tenant_id = p_tenant;

  -- The first register ever taken for this batch. Before that date a
  -- class day is not a missed register, it is simply a day the batch
  -- did not exist yet, and telling a new coach they have missed forty
  -- registers is a lie that trains them to ignore the number.
  select min(s.on_date) into v_first
    from sessions s where s.tenant_id = p_tenant and s.batch_id = p_batch;

  with days as (
    select generate_series(v_from, v_to, interval '1 day')::date as d
  ),
  sess as (
    select s.on_date, s.status,
           count(ar.*) filter (where ar.status = 'present')::int as present,
           count(ar.*) filter (where ar.status = 'absent')::int  as absent
      from sessions s
      left join attendance_records ar on ar.session_id = s.id
     where s.tenant_id = p_tenant and s.batch_id = p_batch
       and s.on_date between v_from and v_to
     group by s.on_date, s.status
  ),
  cal as (
    select d.d as on_date,
           (extract(isodow from d.d)::int = any(v_days)) as scheduled,
           case
             when sess.status = 'held'      then 'held'
             when sess.status = 'cancelled' then 'off'
             when extract(isodow from d.d)::int = any(v_days)
                  and d.d <= v_today
                  and v_first is not null and d.d >= v_first then 'missing'
             else 'none'
           end as state,
           coalesce(sess.present, 0) as present,
           coalesce(sess.absent, 0)  as absent
      from days d
      left join sess on sess.on_date = d.d
  ),
  -- Everything below counts only sessions that were actually HELD. A
  -- cancelled session is not an absence: nobody was asked to come.
  held as (
    select s.id, s.on_date
      from sessions s
     where s.tenant_id = p_tenant and s.batch_id = p_batch
       and s.status = 'held' and s.on_date between v_from and v_to
  ),
  marks as (
    select ar.enrollment_id, ar.status, h.on_date
      from attendance_records ar
      join held h on h.id = ar.session_id
  ),
  roster as (
    select e.id as enrollment_id, m.name as member_name, e.status as enrollment_status
      from enrollments e
      join members m on m.id = e.member_id
     where e.tenant_id = p_tenant and e.batch_id = p_batch
       -- someone who left mid-range still explains the history
       and (e.status = 'active'
            or exists (select 1 from marks k where k.enrollment_id = e.id))
  ),
  per as (
    select r.enrollment_id, r.member_name, r.enrollment_status,
           count(k.*)::int                                      as sessions,
           count(*) filter (where k.status = 'present')::int     as present,
           count(*) filter (where k.status = 'absent')::int      as absent,
           max(k.on_date) filter (where k.status = 'present')    as last_present
      from roster r
      left join marks k on k.enrollment_id = r.enrollment_id
     group by r.enrollment_id, r.member_name, r.enrollment_status
  ),
  -- The absent streak runs back past the window: "three in a row" is
  -- about the child, not about the month boundary the screen happens
  -- to be showing.
  recent as (
    select ar.enrollment_id, ar.status,
           row_number() over (partition by ar.enrollment_id order by s.on_date desc) as rn
      from attendance_records ar
      join sessions s on s.id = ar.session_id and s.status = 'held'
     where s.tenant_id = p_tenant and s.batch_id = p_batch and s.on_date <= v_to
  ),
  streaks as (
    select enrollment_id,
           coalesce(min(rn) filter (where status = 'present'), count(*) + 1) - 1 as absent_streak
      from recent group by enrollment_id
  ),
  student as (
    select p.*, coalesce(s.absent_streak, 0)::int as absent_streak,
           round(100.0 * p.present / nullif(p.present + p.absent, 0)) as rate
      from per p left join streaks s on s.enrollment_id = p.enrollment_id
  )
  select jsonb_build_object(
    'batch', (
      select jsonb_build_object(
        'id', b.id, 'name', b.name, 'sport', b.sport,
        'centre', coalesce(c.short_name, c.name),
        'start_time', b.start_time, 'end_time', b.end_time, 'days', b.days)
        from batches b join centres c on c.id = b.centre_id
       where b.id = p_batch),
    'range', jsonb_build_object('from', v_from, 'to', v_to, 'today', v_today,
                                'first_session', v_first),
    'summary', (
      select jsonb_build_object(
        'held',    count(*) filter (where state = 'held'),
        'off',     count(*) filter (where state = 'off'),
        'missing', count(*) filter (where state = 'missing'),
        'present', coalesce(sum(present), 0),
        'absent',  coalesce(sum(absent), 0),
        'rate',    round(100.0 * sum(present) / nullif(sum(present) + sum(absent), 0)),
        'avg_present', round(sum(present)::numeric
                             / nullif(count(*) filter (where state = 'held'), 0), 1),
        'students', (select count(*) from student where enrollment_status = 'active'),
        'watch',    (select count(*) from student
                      where absent_streak >= 3 or (sessions >= 3 and rate < 60)))
        from cal),
    'calendar', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date', on_date, 'scheduled', scheduled, 'state', state,
               'present', present, 'absent', absent) order by on_date)
        from cal), '[]'::jsonb),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
               'enrollment_id', enrollment_id, 'name', member_name,
               'status', enrollment_status, 'sessions', sessions,
               'present', present, 'absent', absent, 'rate', rate,
               'absent_streak', absent_streak, 'last_present', last_present)
             order by absent_streak desc, rate asc nulls last, member_name)
        from student), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $$;

comment on function my_attendance_insights(text, bigint, date, date) is
  'Per-batch attendance calendar, rates and per-student standing for the caller. p_batch is a required target so assert_attendance_access can hold a coach to their own centres; contains no money and no phone numbers.';

-- Default-closed. The grant to PUBLIC is the one that matters; revoking
-- anon alone is a no-op.
revoke execute on function my_attendance_insights(text, bigint, date, date) from public, anon;
grant  execute on function my_attendance_insights(text, bigint, date, date) to authenticated, service_role;
