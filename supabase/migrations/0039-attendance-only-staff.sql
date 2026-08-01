-- ============================================================
-- 0039 — attendance-only staff, scoped to their own centres
--
-- Coaches take the register; they are not the people who see fees,
-- reminders or anyone's phone number. So this adds a THIRD role that
-- can do exactly one job, at exactly the centres it is assigned to.
--
-- The safety property that makes this small: a coach never queries a
-- table. Every existing RLS policy tests `auth_role() = 'staff'`, which
-- a coach fails, so PostgREST returns nothing for members, payments,
-- fee_rules, reminder_events, everything. A coach can only reach data
-- through the handful of SECURITY DEFINER attendance functions below,
-- each of which checks the batch's centre against their assignment.
--
-- Deliberately NOT done: loosening assert_staff() to accept coaches.
-- That one line guards record_fee_payment, reminder_queue, payouts and
-- every other definer function on the platform, so widening it to let a
-- coach mark a register would have handed them the whole academy.
--
-- Generic on purpose: any academy with more than one venue needs this.
-- ============================================================

-- ------------------------------------------------------------
-- Who is assigned where.
-- ------------------------------------------------------------
create table if not exists staff_scopes (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  auth_uid   uuid,                       -- the Supabase Auth user
  email      text not null,
  name       text not null,
  role       text not null default 'coach' check (role in ('coach')),
  centre_ids bigint[] not null default '{}',
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists staff_scopes_email_uniq
  on staff_scopes (tenant_id, lower(email));
create index if not exists staff_scopes_uid_idx on staff_scopes (auth_uid);

comment on table staff_scopes is
  'Attendance-only staff and the centres each may mark. Read through my_centres(); never queried directly by a client.';

alter table staff_scopes enable row level security;
drop policy if exists staff_scopes_staff_r on staff_scopes;
create policy staff_scopes_staff_r on staff_scopes for select
  using (auth_role() = 'operator'
         or (auth_role() = 'staff' and tenant_id = auth_tenant()));
drop policy if exists staff_scopes_staff_w on staff_scopes;
create policy staff_scopes_staff_w on staff_scopes for insert
  with check (auth_role() = 'staff' and tenant_id = auth_tenant());
drop policy if exists staff_scopes_staff_u on staff_scopes;
create policy staff_scopes_staff_u on staff_scopes for update
  using (auth_role() = 'staff' and tenant_id = auth_tenant());
drop policy if exists staff_scopes_staff_d on staff_scopes;
create policy staff_scopes_staff_d on staff_scopes for delete
  using (auth_role() = 'staff' and tenant_id = auth_tenant());

-- ------------------------------------------------------------
-- The centres the caller may mark. A definer function, because a
-- policy predicate runs as the CALLING role and a coach cannot read
-- staff_scopes: an inlined subquery would silently return nothing and
-- deny everything. That mistake has cost this platform two outages.
-- ------------------------------------------------------------
create or replace function my_centres(p_tenant text)
  returns bigint[]
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select s.centre_ids from staff_scopes s
      where s.tenant_id = p_tenant and s.active
        and (s.auth_uid = auth.uid()
             or lower(s.email) = lower(coalesce(auth.jwt()->>'email','')))
      limit 1),
    '{}')
$$;
revoke execute on function my_centres(text) from public, anon;
grant  execute on function my_centres(text) to authenticated, service_role;

-- ------------------------------------------------------------
-- The guard the attendance functions use instead of assert_staff.
-- Operators and staff keep full reach; a coach is held to their
-- assigned centres.
-- ------------------------------------------------------------
create or replace function assert_attendance_access(p_tenant text, p_batch bigint)
  returns void
  language plpgsql stable security definer set search_path = public as $$
declare v_centre bigint; v_centres bigint[];
begin
  if is_service() then return; end if;
  if not is_locked() then return; end if;
  if auth_role() = 'operator' then return; end if;
  if auth_role() = 'staff' and auth_tenant() = p_tenant then return; end if;

  if auth_role() = 'coach' and auth_tenant() = p_tenant then
    select centre_id into v_centre from batches
     where id = p_batch and tenant_id = p_tenant;
    if v_centre is null then raise exception 'batch not found'; end if;
    v_centres := my_centres(p_tenant);
    if v_centre = any(v_centres) then return; end if;
    raise exception 'You are not assigned to that centre.' using errcode = 'insufficient_privilege';
  end if;

  raise exception 'not authorised' using errcode = 'insufficient_privilege';
end $$;
revoke execute on function assert_attendance_access(text, bigint) from public, anon;
grant  execute on function assert_attendance_access(text, bigint) to authenticated, service_role;

-- ------------------------------------------------------------
-- The register a coach may take today. This is the ONLY way a coach
-- discovers batches, so it returns just enough to render the screen
-- and nothing about money.
-- ------------------------------------------------------------
create or replace function my_attendance_batches(p_tenant text, p_date date default null)
  returns table (
    batch_id bigint, batch_name text, centre_id bigint, centre_name text,
    sport text, start_time time, end_time time, days int[],
    runs_today boolean, students int, marked int, session_status text
  )
  language sql stable security definer set search_path = public as $$
  with me as (
    select (case
      when is_service() or auth_role() in ('operator','staff')
        then (select coalesce(array_agg(c2.id), '{}') from centres c2 where c2.tenant_id = p_tenant)
      else my_centres(p_tenant) end)::bigint[] as centres
  ), d as (select coalesce(p_date, ist_today()) as day)
  select b.id, b.name, c.id, coalesce(c.short_name, c.name), b.sport,
         b.start_time, b.end_time, b.days,
         (extract(isodow from (select day from d))::int = any(b.days)) as runs_today,
         (select count(*)::int from enrollments e
           where e.batch_id = b.id and e.status = 'active') as students,
         (select count(*)::int from attendance_records ar
            join sessions s on s.id = ar.session_id
           where s.batch_id = b.id and s.on_date = (select day from d)) as marked,
         (select s.status from sessions s
           where s.batch_id = b.id and s.on_date = (select day from d) limit 1) as session_status
    from batches b
    join centres c on c.id = b.centre_id
    cross join me
   where b.tenant_id = p_tenant and b.active
     and b.centre_id = any(me.centres)
   order by c.sort, b.sort
$$;
revoke execute on function my_attendance_batches(text, date) from public, anon;
grant  execute on function my_attendance_batches(text, date) to authenticated, service_role;

-- Who am I, and what may I do? One call the app uses to route after
-- sign-in, so a coach never lands on a screen they cannot load.
create or replace function my_access()
  returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'role', auth_role(),
    'tenant', auth_tenant(),
    'email', coalesce(auth.jwt()->>'email',''),
    'centres', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', coalesce(c.short_name, c.name))
             order by c.sort)
        from centres c
       where c.tenant_id = auth_tenant()
         and (auth_role() in ('operator','staff')
              or c.id = any(my_centres(auth_tenant())))), '[]'::jsonb))
$$;
revoke execute on function my_access() from public, anon;
grant  execute on function my_access() to authenticated, service_role;

-- ------------------------------------------------------------
-- Managing assignments from the manager app.
-- ------------------------------------------------------------
create or replace function set_staff_scope(
  p_tenant text, p_email text, p_name text,
  p_centres bigint[], p_active boolean default true
) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_uid uuid;
begin
  perform assert_staff_or_service(p_tenant);
  if coalesce(trim(p_email),'') = '' then
    raise exception 'An email is required.' using errcode = 'check_violation';
  end if;
  -- Only centres this academy owns; a typo must not grant reach
  -- elsewhere. NOT IN is null-propagating, so a null in the array would
  -- make the whole test null and quietly pass: check for nulls first.
  if exists (select 1 from unnest(coalesce(p_centres,'{}')) cid where cid is null) then
    raise exception 'Centre list contains an empty value.' using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_centres,'{}')) cid
     where not exists (select 1 from centres c
                        where c.id = cid and c.tenant_id = p_tenant)) then
    raise exception 'That centre does not belong to this academy.' using errcode = 'check_violation';
  end if;

  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));

  insert into staff_scopes (tenant_id, auth_uid, email, name, centre_ids, active)
  values (p_tenant, v_uid, lower(trim(p_email)), trim(p_name),
          coalesce(p_centres,'{}'), coalesce(p_active, true))
  on conflict (tenant_id, lower(email)) do update
    set auth_uid = coalesce(excluded.auth_uid, staff_scopes.auth_uid),
        name = excluded.name, centre_ids = excluded.centre_ids,
        active = excluded.active, updated_at = now()
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'linked', v_uid is not null);
end $$;
revoke execute on function set_staff_scope(text, text, text, bigint[], boolean) from public, anon;
grant  execute on function set_staff_scope(text, text, text, bigint[], boolean) to authenticated, service_role;

-- ------------------------------------------------------------
-- Re-guard the three attendance functions. Bodies below are the live
-- definitions with ONLY the guard line changed, so behaviour that
-- already works cannot regress on the way through.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attendance_roster(p_tenant text, p_batch bigint, p_date date DEFAULT NULL::date)
 RETURNS TABLE(session_id bigint, session_status text, session_note text, session_marked_at timestamp with time zone, session_marked_by text, enrollment_id bigint, member_id bigint, member_name text, parent_name text, phone text, sport text, attendance_id bigint, attendance_status text, reason text, attendance_note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d date := coalesce(p_date, ist_today());
begin
  perform assert_attendance_access(p_tenant, p_batch);
  if not exists (
    select 1 from batches b where b.id=p_batch and b.tenant_id=p_tenant
  ) then
    raise exception 'batch not found';
  end if;

  return query
  with target_session as (
    select s.*
      from sessions s
     where s.tenant_id=p_tenant and s.batch_id=p_batch and s.on_date=d
  ),
  roster_ids as (
    select e.id
      from enrollments e
      join members m on m.id=e.member_id
     where e.tenant_id=p_tenant
       and e.batch_id=p_batch
       and e.status='active'
       and m.status <> 'discontinued'
       and e.joined_on <= d
    union
    select ar.enrollment_id
      from attendance_records ar
      join target_session s on s.id=ar.session_id
  )
  select
    s.id, s.status, s.note, s.marked_at, s.marked_by,
    e.id, m.id, m.name, m.parent_name,
    coalesce(nullif(m.parent_phone,''), nullif(m.phone,'')),
    e.sport,
    ar.id, ar.status, ar.reason, ar.note
  from roster_ids r
  join enrollments e on e.id=r.id and e.tenant_id=p_tenant
  join members m on m.id=e.member_id
  left join target_session s on true
  left join attendance_records ar
    on ar.session_id=s.id and ar.enrollment_id=e.id
  order by m.name, e.id;
end $function$;

CREATE OR REPLACE FUNCTION public.mark_attendance(p_tenant text, p_batch bigint, p_date date, p_enrollment bigint, p_status text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b batches;
  sid bigint;
  actor text := coalesce(nullif(auth.jwt()->>'email',''), 'system');
  expected_count int;
  marked_count int;
  present_count int;
  absent_count int;
begin
  perform assert_attendance_access(p_tenant, p_batch);
  if p_date is null then raise exception 'session date is required'; end if;
  if p_date > ist_today() then
    raise exception 'Attendance cannot be taken for a future date';
  end if;
  if p_status is not null and p_status not in ('present','absent') then
    raise exception 'invalid attendance status';
  end if;

  select * into b
    from batches
   where id=p_batch and tenant_id=p_tenant;
  if not found then raise exception 'batch not found'; end if;

  if not exists (
    select 1
      from enrollments e
      join members m on m.id=e.member_id
     where e.id=p_enrollment
       and e.tenant_id=p_tenant
       and e.batch_id=p_batch
       and e.joined_on <= p_date
       and (
         (e.status='active' and m.status <> 'discontinued')
         or exists (
           select 1
             from attendance_records ar
             join sessions s on s.id=ar.session_id
            where ar.enrollment_id=e.id
              and s.tenant_id=p_tenant
              and s.batch_id=p_batch
              and s.on_date=p_date
         )
       )
  ) then
    raise exception 'student is not in this batch';
  end if;

  select id into sid
    from sessions
   where tenant_id=p_tenant and batch_id=p_batch and on_date=p_date;

  if p_status is null then
    if sid is not null then
      delete from attendance_records
       where tenant_id=p_tenant
         and session_id=sid
         and enrollment_id=p_enrollment;

      update sessions set
        marked_at=now(), marked_by=actor, updated_at=now()
       where id=sid;

      if not exists (select 1 from attendance_records where session_id=sid)
         and (select note is null from sessions where id=sid) then
        delete from sessions where id=sid;
        sid := null;
      end if;
    end if;
  else
    insert into sessions (
      tenant_id, batch_id, on_date, coach_id, status,
      scheduled_start, scheduled_end, marked_at, marked_by,
      cancel_reason, updated_at
    ) values (
      p_tenant, b.id, p_date, b.coach_id, 'held',
      b.start_time, b.end_time, now(), actor, null, now()
    )
    on conflict (tenant_id, batch_id, on_date) do update set
      status='held',
      coach_id=excluded.coach_id,
      scheduled_start=coalesce(sessions.scheduled_start, excluded.scheduled_start),
      scheduled_end=coalesce(sessions.scheduled_end, excluded.scheduled_end),
      marked_at=excluded.marked_at,
      marked_by=excluded.marked_by,
      cancel_reason=null,
      updated_at=now()
    returning id into sid;

    insert into attendance_records (
      tenant_id, session_id, enrollment_id, status,
      reason, marked_at, marked_by, updated_at
    ) values (
      p_tenant, sid, p_enrollment, p_status,
      case when p_status='absent' then nullif(trim(p_reason),'') else null end,
      now(), actor, now()
    )
    on conflict (session_id, enrollment_id) do update set
      status=excluded.status,
      reason=excluded.reason,
      marked_at=excluded.marked_at,
      marked_by=excluded.marked_by,
      updated_at=now();
  end if;

  select count(*) into expected_count
  from (
    select e.id
      from enrollments e
      join members m on m.id=e.member_id
     where e.tenant_id=p_tenant
       and e.batch_id=p_batch
       and e.status='active'
       and e.joined_on <= p_date
       and m.status <> 'discontinued'
    union
    select ar.enrollment_id
      from attendance_records ar
      join sessions s on s.id=ar.session_id
     where s.tenant_id=p_tenant
       and s.batch_id=p_batch
       and s.on_date=p_date
  ) roster;

  select
    count(*),
    count(*) filter (where status='present'),
    count(*) filter (where status='absent')
    into marked_count, present_count, absent_count
  from attendance_records
  where tenant_id=p_tenant and session_id=sid;

  return jsonb_build_object(
    'session_id', sid,
    'status', p_status,
    'saved_at', now(),
    'marked', coalesce(marked_count,0),
    'total', expected_count,
    'present', coalesce(present_count,0),
    'absent', coalesce(absent_count,0)
  );
end $function$;

CREATE OR REPLACE FUNCTION public.save_attendance_session(p_tenant text, p_batch bigint, p_date date, p_status text, p_rows jsonb DEFAULT '[]'::jsonb, p_note text DEFAULT NULL::text, p_cancel_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b batches;
  sid bigint;
  expected_count int;
  provided_count int;
  distinct_count int;
  bad_count int;
  actor text := coalesce(nullif(auth.jwt()->>'email',''), 'system');
  result jsonb;
begin
  perform assert_attendance_access(p_tenant, p_batch);
  if p_date is null then raise exception 'session date is required'; end if;
  if p_date > ist_today() then raise exception 'Attendance cannot be taken for a future date'; end if;
  if p_status not in ('held','cancelled') then raise exception 'invalid session status'; end if;

  select * into b from batches where id=p_batch and tenant_id=p_tenant;
  if not found then raise exception 'batch not found'; end if;

  insert into sessions (
    tenant_id, batch_id, on_date, coach_id, status, note,
    scheduled_start, scheduled_end, marked_at, marked_by,
    cancel_reason, updated_at
  ) values (
    p_tenant, b.id, p_date, b.coach_id, p_status, nullif(trim(p_note),''),
    b.start_time, b.end_time, now(), actor,
    case when p_status='cancelled' then nullif(trim(p_cancel_reason),'') else null end,
    now()
  )
  on conflict (tenant_id, batch_id, on_date) do update set
    coach_id=excluded.coach_id,
    status=excluded.status,
    note=excluded.note,
    scheduled_start=coalesce(sessions.scheduled_start, excluded.scheduled_start),
    scheduled_end=coalesce(sessions.scheduled_end, excluded.scheduled_end),
    marked_at=excluded.marked_at,
    marked_by=excluded.marked_by,
    cancel_reason=excluded.cancel_reason,
    updated_at=now()
  returning id into sid;

  if p_status='cancelled' then
    delete from attendance_records where tenant_id=p_tenant and session_id=sid;
    return jsonb_build_object(
      'session_id', sid, 'status', 'cancelled', 'saved_at', now(),
      'present', 0, 'absent', 0
    );
  end if;

  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception 'attendance rows must be an array';
  end if;

  select count(*), count(distinct (x->>'enrollment_id')::bigint)
    into provided_count, distinct_count
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x;
  if provided_count <> distinct_count then
    raise exception 'the same student appears more than once';
  end if;

  select count(*) into expected_count
  from (
    select e.id
      from enrollments e
      join members m on m.id=e.member_id
     where e.tenant_id=p_tenant and e.batch_id=p_batch
       and e.status='active' and m.status <> 'discontinued'
       and e.joined_on <= p_date
    union
    select ar.enrollment_id
      from attendance_records ar
     where ar.tenant_id=p_tenant and ar.session_id=sid
  ) expected;

  if expected_count = 0 then raise exception 'This batch has no students to mark'; end if;
  if provided_count <> expected_count then
    raise exception 'Mark every student before saving (% of % marked)',
      provided_count, expected_count;
  end if;

  select count(*) into bad_count
    from jsonb_array_elements(p_rows) x
    left join enrollments e
      on e.id=(x->>'enrollment_id')::bigint
     and e.tenant_id=p_tenant and e.batch_id=p_batch
   where e.id is null
      or coalesce(x->>'status','') not in ('present','absent');
  if bad_count > 0 then raise exception 'attendance contains an invalid student or status'; end if;

  delete from attendance_records ar
   where ar.tenant_id=p_tenant and ar.session_id=sid
     and not exists (
       select 1 from jsonb_array_elements(p_rows) x
        where (x->>'enrollment_id')::bigint=ar.enrollment_id
     );

  insert into attendance_records (
    tenant_id, session_id, enrollment_id, status,
    reason, note, marked_at, marked_by, updated_at
  )
  select
    p_tenant, sid, (x->>'enrollment_id')::bigint, x->>'status',
    nullif(trim(x->>'reason'),''),
    nullif(trim(x->>'note'),''),
    now(), actor, now()
  from jsonb_array_elements(p_rows) x
  on conflict (session_id, enrollment_id) do update set
    status=excluded.status,
    reason=excluded.reason,
    note=excluded.note,
    marked_at=excluded.marked_at,
    marked_by=excluded.marked_by,
    updated_at=now();

  select jsonb_build_object(
    'session_id', sid,
    'status', 'held',
    'saved_at', now(),
    'present', count(*) filter (where status='present'),
    'absent', count(*) filter (where status='absent')
  ) into result
  from attendance_records
  where tenant_id=p_tenant and session_id=sid;

  return result;
end $function$;

revoke execute on function attendance_roster(text, bigint, date) from public, anon;
grant  execute on function attendance_roster(text, bigint, date) to authenticated, service_role;
revoke execute on function mark_attendance(text, bigint, date, bigint, text, text) from public, anon;
grant  execute on function mark_attendance(text, bigint, date, bigint, text, text) to authenticated, service_role;
revoke execute on function save_attendance_session(text, bigint, date, text, jsonb, text, text) from public, anon;
grant  execute on function save_attendance_session(text, bigint, date, text, jsonb, text, text) to authenticated, service_role;
