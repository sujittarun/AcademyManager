-- ============================================================
-- 2026-08-01d — a register due today is not a register missed
--
-- 2026-08-01c marked every scheduled class day up to and including
-- today with no session row as 'missing'. That paints the current day
-- brick red before the batch has even met, so a coach opening the
-- screen in the morning is told off for a session that is still hours
-- away. The whole point of the colour is that it means "go and fix
-- something", and a number that cries wolf on every single morning is
-- one a coach learns to ignore.
--
-- So: 'missing' is now strictly BEFORE today. Today keeps state 'none'
-- with scheduled = true, which the client already draws as "still to
-- come".
--
-- A new file rather than an edit of 01c: the ledger is keyed on
-- filename + sha256, and rewriting an applied file is exactly what it
-- refuses.
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
  if p_batch is null then
    raise exception 'A batch is required.' using errcode = 'check_violation';
  end if;
  perform assert_attendance_access(p_tenant, p_batch);

  if v_from > v_to then
    raise exception 'The start date is after the end date.' using errcode = 'check_violation';
  end if;
  if v_to - v_from > 400 then
    raise exception 'That range is too long.' using errcode = 'check_violation';
  end if;

  select b.days into v_days
    from batches b where b.id = p_batch and b.tenant_id = p_tenant;

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
             -- strictly before today: a class that has already come and
             -- gone with nobody marking it
             when extract(isodow from d.d)::int = any(v_days)
                  and d.d < v_today
                  and v_first is not null and d.d >= v_first then 'missing'
             else 'none'
           end as state,
           coalesce(sess.present, 0) as present,
           coalesce(sess.absent, 0)  as absent
      from days d
      left join sess on sess.on_date = d.d
  ),
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

revoke execute on function my_attendance_insights(text, bigint, date, date) from public, anon;
grant  execute on function my_attendance_insights(text, bigint, date, date) to authenticated, service_role;
