-- ============================================================
-- 0028 · Leaving and coming back — one write path each
-- scope: shared
--
-- A student who stops coming, and the same student who walks back in
-- three months later. Both are two-row changes today, done from the
-- client as two separate PATCHes:
--
--   members.status     = 'discontinued'  + discontinued_on
--   enrollments.status = 'discontinued'  + discontinued_on
--
-- Two writes that must agree, with no transaction around them. If the
-- second fails you get an enrolment marked discontinued under a member
-- still counted as active — and `active_players` in the operator console
-- reads `members.status in ('active','due')`, so that half-failure is
-- visible in the platform's own numbers and nowhere else.
--
-- Coming back is worse. Every client's "add student" inserts a NEW
-- member row, so a returning student gets a second identity and their
-- payments, timeline and tenure stay stranded on the old one. The
-- obvious alternative — flipping the old row back to active — reuses the
-- SAME enrolment, so renewal_on is still the date they left. The moment
-- they are active again reminder_queue computes days_since in the
-- hundreds and returns them blocked with 'overdue_15_days': the bucket
-- that means STOP, a human must call. A student who just rejoined lands
-- in the do-not-message pile.
--
-- So: one member, many enrolments, never two live at once. Each spell is
-- an enrolment row, which is what makes a rejoin legible afterwards —
-- `enrollments.joined_on -> discontinued_on` per spell is exactly what
-- the tenant apps already render as "Rejoined".
--
-- Nothing here computes money. resolve_fee still prices the new
-- enrolment and record_fee_payment still moves the renewal date; these
-- two only open and close a spell.
--
-- Shared on purpose. members and enrollments belong to every tenant, and
-- "you cannot hold two live enrolments at once" is a platform
-- invariant, not one academy's preference. Written once here rather than
-- six times in six clients.
-- ============================================================

-- ------------------------------------------------------------
-- Leaving.
--
-- Idempotent: discontinuing someone already discontinued is a no-op that
-- reports what it found, not an error. The owner tapping twice on a bad
-- connection must not be punished for it.
-- ------------------------------------------------------------
create or replace function discontinue_member(
  p_tenant  text,
  p_member  bigint,
  p_on_date date default null,
  p_reason  text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $$
declare
  v_on      date := coalesce(p_on_date, ist_today());
  v_name    text;
  v_closed  int;
begin
  perform assert_staff_or_service(p_tenant);

  -- The tenant check is not ceremony: p_member is a bare id, so without
  -- it a signed-in staff member of one academy could close a student at
  -- another. Same reason resolve_fee takes p_tenant.
  select name into v_name
    from members
   where id = p_member and tenant_id = p_tenant;
  if v_name is null then
    raise exception 'member % is not in tenant %', p_member, p_tenant;
  end if;

  -- Close every live spell, not just one. 'paused' counts as live: it
  -- means "not training this month", not "gone".
  update enrollments
     set status          = 'discontinued',
         discontinued_on = coalesce(discontinued_on, v_on),
         updated_at      = now()
   where tenant_id = p_tenant
     and member_id = p_member
     and status in ('active', 'paused');
  get diagnostics v_closed = row_count;

  update members
     set status          = 'discontinued',
         discontinued_on = coalesce(discontinued_on, v_on),
         updated_at      = now()
   where id = p_member and tenant_id = p_tenant;

  -- Only leave a trace when something actually changed, so a double tap
  -- does not write a second "left the academy" into their history.
  if v_closed > 0 then
    insert into member_timeline (tenant_id, member_id, kind, title, body, meta)
    values (p_tenant, p_member, 'system', 'Left the academy', p_reason,
            jsonb_build_object('on', v_on, 'enrollments_closed', v_closed));
  end if;

  return jsonb_build_object(
    'member_id',          p_member,
    'discontinued_on',    v_on,
    'enrollments_closed', v_closed
  );
end $$;

-- ------------------------------------------------------------
-- Coming back.
--
-- Returns the new enrolment so the caller can price it and record the
-- first payment against it without a second lookup.
-- ------------------------------------------------------------
create or replace function reenroll_member(
  p_tenant        text,
  p_member        bigint,
  p_centre        bigint,
  p_batch         bigint  default null,
  p_sport         text    default null,
  p_joined_on     date    default null,
  p_renewal_on    date    default null,
  p_plan_months   int     default 1,
  p_custom_amount numeric default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $$
declare
  v_on       date := coalesce(p_joined_on, ist_today());
  v_sport    text;
  v_prev     record;
  v_new      bigint;
  v_renewal  date;
begin
  perform assert_staff_or_service(p_tenant);

  select * into v_prev
    from members
   where id = p_member and tenant_id = p_tenant;
  if v_prev.id is null then
    raise exception 'member % is not in tenant %', p_member, p_tenant;
  end if;

  -- THE GUARD. Without this, "bring back" on someone who never left
  -- silently creates a second live enrolment, and every read that picks
  -- "the active one" starts picking arbitrarily. Refusing here means no
  -- client has to remember to check.
  if exists (
    select 1 from enrollments
     where tenant_id = p_tenant and member_id = p_member
       and status in ('active', 'paused')
  ) then
    raise exception '% is already enrolled — edit that enrolment instead of adding another',
      v_prev.name;
  end if;

  -- Their last sport unless told otherwise: an academy that runs one
  -- sport should not have to pass it, and one that runs several will.
  select e.sport into v_sport
    from enrollments e
   where e.tenant_id = p_tenant and e.member_id = p_member
   order by coalesce(e.discontinued_on, e.joined_on) desc nulls last, e.id desc
   limit 1;
  v_sport := coalesce(p_sport, v_sport);
  if v_sport is null then
    raise exception 'no sport given and no previous enrolment to take one from';
  end if;

  -- The whole point of the rejoin. A returning student enters the
  -- reminder ladder at day 0, not at however many days have passed since
  -- they left — which is what reusing the old enrolment would do.
  v_renewal := coalesce(p_renewal_on, v_on);

  insert into enrollments (
    tenant_id, member_id, centre_id, batch_id, sport,
    plan_months, custom_amount, joined_on, renewal_on, status
  ) values (
    p_tenant, p_member, p_centre, p_batch, v_sport,
    coalesce(p_plan_months, 1), p_custom_amount, v_on, v_renewal, 'active'
  ) returning id into v_new;

  -- Back on the roll, and the old leaving date cleared. Leaving it set
  -- would put a member on the books with a date saying they are gone.
  update members
     set status          = 'active',
         discontinued_on = null,
         updated_at      = now()
   where id = p_member and tenant_id = p_tenant;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, p_member, v_new, 'system', 'Rejoined',
          case when v_prev.discontinued_on is not null
               then 'Away since ' || to_char(v_prev.discontinued_on, 'DD Mon YYYY')
          end,
          jsonb_build_object('joined_on', v_on, 'renewal_on', v_renewal, 'sport', v_sport));

  return jsonb_build_object(
    'member_id',     p_member,
    'enrollment_id', v_new,
    'joined_on',     v_on,
    'renewal_on',    v_renewal,
    'sport',         v_sport
  );
end $$;

-- ------------------------------------------------------------
-- Grants.
--
-- The default grant is to PUBLIC, and `revoke ... from anon` alone is a
-- no-op — it is the bare `=X/postgres` in the ACL that makes a function
-- anon-callable. Revoke from the pseudo-role, then grant back.
--
-- Neither of these is on an anonymous path, so there is nothing here
-- that a policy or a public endpoint calls.
-- ------------------------------------------------------------
revoke execute on function discontinue_member(text, bigint, date, text) from public, anon;
revoke execute on function reenroll_member(text, bigint, bigint, bigint, text, date, date, int, numeric) from public, anon;

grant execute on function discontinue_member(text, bigint, date, text) to authenticated, service_role;
grant execute on function reenroll_member(text, bigint, bigint, bigint, text, date, date, int, numeric) to authenticated, service_role;

-- ------------------------------------------------------------
-- Assert the shape, loudly. 0004 is the reason: a migration that
-- "succeeded" and changed nothing is worse than one that failed.
-- ------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.proname, p.prosecdef, p.proacl
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('discontinue_member', 'reenroll_member')
  loop
    if not r.prosecdef then
      raise exception '% is not SECURITY DEFINER', r.proname;
    end if;
    -- The ACL is explicit after the revoke above; a null one would mean
    -- the default, which is PUBLIC.
    if r.proacl is null then
      raise exception '% still carries the default PUBLIC grant', r.proname;
    end if;
    if array_to_string(r.proacl, ' ') like '%anon=%' then
      raise exception '% is executable by anon', r.proname;
    end if;
  end loop;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('discontinue_member', 'reenroll_member')) <> 2 then
    raise exception 'expected both lifecycle functions to exist';
  end if;

  raise notice 'member lifecycle ready: discontinue_member + reenroll_member, staff-guarded';
end $$;
