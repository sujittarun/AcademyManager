-- ============================================================
-- 2026-09-03a · A corrected joining date moves the member row too
-- scope: shared
--
-- "for G. Ramchandan change the joing month and payment month from august
--  to september keep the dates same"
--
-- He was entered on 3 Sep with a joining date of 2 AUGUST, so the academy
-- saw a boy who had been enrolled a month and owed a month. He joined on
-- 2 SEPTEMBER. Nothing has been paid yet — no payment row of any status —
-- so the joining day is still the cycle anchor (2026-08-24d), and moving
-- it moves both the biography and the money.
--
-- set_joining_date (2026-08-24f) already owns that rule, and this is its
-- first ever call — member_timeline has no 'Joining date corrected' row.
-- Being first, it exposed the gap:
--
--   it writes enrollments.joined_on, and nothing writes members.joined
--
-- For GenAlpha those are not two views of one fact, they are two columns,
-- and the app reads the one the function does not write:
--
--   genalpha.students.join_date    -> m.joined
--   genalpha.students.paid_through -> e.renewal_on
--
-- So the sanctioned correction would have fixed the cycle and left every
-- screen still saying 2 Aug — a fix that reports success and shows the old
-- answer. Patching this one student's rows by hand would have hidden that
-- from the next caller, so the function is fixed instead.
--
-- WHEN THE MEMBER ROW MUST *NOT* FOLLOW. members.joined is per member and
-- joined_on is per enrolment, so a member enrolled in two sports has one
-- of the first and two of the second — they cannot agree, and neither is
-- wrong. Measured before writing this:
--
--   demo 94/94 agree · genalpha 88/88 · mezzo 74/74 · mpp 1/1 · ska 1/1
--   raj  104 agree, 8 differ — and all 8 are multi-enrolment members
--
-- That is the whole rule: follow when the member has exactly one enrolment,
-- leave alone when they have several. Not a special case for Raj — a member
-- with two enrolments has no single joining date to write.
-- ============================================================

create or replace function public.set_joining_date(
  p_tenant text, p_enrollment bigint, p_on_date date)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  e enrollments; m members; v_paid int; v_ren date; v_enrols int; v_member_moved boolean := false;
begin
  perform assert_staff_or_service(p_tenant);

  if p_on_date is null then
    raise exception 'A joining date is needed.' using errcode = 'check_violation';
  end if;
  if p_on_date > ist_today() then
    raise exception 'A joining date cannot be in the future.' using errcode = 'check_violation';
  end if;

  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then
    raise exception 'That student does not belong to this academy.' using errcode = 'no_data_found';
  end if;
  select * into m from members where id = e.member_id;

  select count(*) into v_paid from payments p
   where p.enrollment_id = e.id and p.status <> 'void'
     and coalesce(p.kind,'renewal') <> 'custom' and coalesce(p.months,0) > 0;

  if v_paid = 0 then
    -- Nothing bought yet, so the joining day IS where the cycle starts.
    v_ren := p_on_date;
    update enrollments set joined_on = p_on_date, renewal_on = p_on_date, updated_at = now()
     where id = e.id and tenant_id = p_tenant;
  else
    -- Money has been taken against a cycle. Correct the biography, leave the
    -- cycle alone: re-dating a paid period is what void_payment is for.
    v_ren := e.renewal_on;
    update enrollments set joined_on = p_on_date, updated_at = now()
     where id = e.id and tenant_id = p_tenant;
  end if;

  -- The member's own joining date follows, but only when there is one
  -- enrolment to follow. With two, the member joined the academy once and
  -- each enrolment started on its own day; overwriting members.joined from
  -- whichever one was passed would corrupt the other.
  select count(*) into v_enrols from enrollments e2
   where e2.member_id = e.member_id and e2.tenant_id = p_tenant;

  if v_enrols = 1 then
    update members set joined = p_on_date, updated_at = now()
     where id = e.member_id and tenant_id = p_tenant;
    v_member_moved := true;
  end if;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id, 'system', 'Joining date corrected', null,
          jsonb_build_object('joined_on_before', e.joined_on, 'joined_on', p_on_date,
                             'renewal_on', v_ren, 'fees_taken', v_paid,
                             'member_joined_before', m.joined,
                             'member_joined_moved', v_member_moved,
                             'enrolments', v_enrols));

  return jsonb_build_object('joined_on', p_on_date, 'renewal_on', v_ren,
                            'fees_taken', v_paid, 'name', m.name,
                            'member_joined_moved', v_member_moved);
end $fn$;

revoke execute on function public.set_joining_date(text,bigint,date) from public, anon;
grant  execute on function public.set_joining_date(text,bigint,date) to authenticated, service_role;


-- ------------------------------------------------------------
-- The correction itself. This block WRITES and is meant to commit — it is
-- the point of the file — so it checks what it is about to change first
-- and refuses on anything it does not recognise.
-- ------------------------------------------------------------
do $$
declare
  v_enrol bigint := 2538;              -- G. Ramchandan, member 2675
  v_target date := date '2026-09-02';
  b record; a record; r jsonb;
begin
  select m.name, m.joined as member_joined, e.joined_on, e.renewal_on, e.status,
         (select count(*) from payments p where p.enrollment_id = e.id and p.status <> 'void') as paid
    into b
  from enrollments e join members m on m.id = e.member_id
  where e.id = v_enrol and e.tenant_id = 'genalpha';

  if not found then
    raise exception 'enrolment % is not a genalpha enrolment', v_enrol;
  end if;
  if b.name <> 'G. Ramchandan' then
    raise exception 'enrolment % is %, not G. Ramchandan', v_enrol, b.name;
  end if;
  -- Refuse if someone has already corrected it, or if a fee landed between
  -- writing this file and running it. Either makes the change below wrong.
  if b.member_joined <> date '2026-08-02' or b.joined_on <> date '2026-08-02' then
    raise exception 'expected 2026-08-02 on both, found member=% enrolment=%',
                    b.member_joined, b.joined_on;
  end if;
  if b.paid <> 0 then
    raise exception 'a fee has landed (% payments) — moving the cycle now would re-bill', b.paid;
  end if;

  r := set_joining_date('genalpha', v_enrol, v_target);

  select m.joined as member_joined, e.joined_on, e.renewal_on
    into a
  from enrollments e join members m on m.id = e.member_id
  where e.id = v_enrol;

  if a.member_joined <> v_target then
    raise exception 'members.joined is % — the app would still show August', a.member_joined;
  end if;
  if a.joined_on <> v_target then
    raise exception 'enrollments.joined_on is %', a.joined_on;
  end if;
  if a.renewal_on <> v_target then
    raise exception 'renewal_on is % — the fee is still due in August', a.renewal_on;
  end if;
  if not (r->>'member_joined_moved')::boolean then
    raise exception 'the member row was not moved: %', r;
  end if;

  raise notice 'G. Ramchandan: joined and cycle both 2 Aug -> % (fees taken: %)',
               v_target, r->>'fees_taken';
end $$;


-- ------------------------------------------------------------
-- Read-only: nobody else drifted. The only members whose joining date may
-- differ from their enrolment's are those with more than one enrolment.
-- ------------------------------------------------------------
do $$
declare v_bad int;
begin
  select count(*) into v_bad
  from members m
  join enrollments e on e.member_id = m.id and e.tenant_id = m.tenant_id
  where m.joined is not null and m.joined <> e.joined_on
    and (select count(*) from enrollments e2
          where e2.member_id = m.id and e2.tenant_id = m.tenant_id) = 1;

  if v_bad <> 0 then
    raise exception '% single-enrolment members disagree with their enrolment', v_bad;
  end if;
end $$;
