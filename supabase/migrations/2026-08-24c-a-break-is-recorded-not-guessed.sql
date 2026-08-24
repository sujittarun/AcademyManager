-- ============================================================
-- 2026-08-24c · A break is recorded, not guessed
-- scope: shared
--
-- "student paused and continued after 1.5 month — cycle time should start
--  from the rejoining day, and payment might be on that day or 2-3 days later"
--
-- Pausing was client-side arithmetic. Mezzo asked "away for how long?", offered
-- 1/2/3 months, and PATCHed enrollments.renewal_on forward by the answer --
-- money computed in JavaScript, written straight into the money column. It was
-- a guess made on the day somebody leaves, which is the one day the answer is
-- not knowable, and nothing could correct it afterwards. Resume did not revisit
-- the date at all.
--
-- 2026-08-24b made that guess load-bearing: with mezzo on the chain rule, the
-- anchor is no longer rescued by greatest(renewal_on, paid_on). So the guess
-- has to go before the next pause, not after.
--
--   pause_enrollment   flips the status and touches NO date. How long someone
--                      will be away is not knowable yet.
--   resume_enrollment  records the day they came back in members.rejoined_at
--                      -- the column genalpha has used since 2026-08-21c -- and
--                      moves the anchor there.
--
-- THE ANCHOR MOVES FORWARD, NEVER BACK. greatest() over the current renewal:
-- the days between the last paid period and the return are days nobody taught
-- them, written off rather than billed -- that is what makes a break different
-- from lateness. A student who returns while still paid up keeps the date they
-- already hold; coverage already sold is never resold. Same invariant
-- apply_payment_coverage has always kept.
--
-- Not a threshold anywhere. Nothing infers a break from how late someone is;
-- 29 days late and 31 days late must not be different kinds of thing.
--
-- Only mezzo writes enrollments.status='paused' (raj's four are seed rows that
-- were INSERTed paused and have never moved), so these are reachable by one
-- tenant today even though they are shared.
-- ============================================================

create or replace function public.pause_enrollment(
  p_tenant text, p_enrollment bigint, p_on_date date default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare e enrollments; m members; v_on date := coalesce(p_on_date, ist_today());
begin
  perform assert_staff_or_service(p_tenant);

  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then
    raise exception 'That student does not belong to this academy.' using errcode = 'no_data_found';
  end if;
  select * into m from members where id = e.member_id;

  if e.status = 'discontinued' then
    raise exception '% has already left the academy.', m.name using errcode = 'check_violation';
  end if;
  if e.status = 'paused' then
    raise exception '% is already on a break.', m.name using errcode = 'check_violation';
  end if;
  if v_on > ist_today() then
    raise exception 'A break cannot start in the future.' using errcode = 'check_violation';
  end if;

  -- renewal_on is deliberately untouched. See the header.
  update enrollments set status = 'paused', updated_at = now()
   where id = e.id and tenant_id = p_tenant;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id, 'system', 'On a break',
          nullif(coalesce(p_note, ''), ''),
          jsonb_build_object('paused_on', v_on, 'renewal_on', e.renewal_on, 'sport', e.sport));

  return jsonb_build_object('status', 'paused', 'paused_on', v_on, 'renewal_on', e.renewal_on);
end $fn$;

create or replace function public.resume_enrollment(
  p_tenant text, p_enrollment bigint, p_on_date date default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  e enrollments; m members;
  v_on date := coalesce(p_on_date, ist_today());
  v_before date; v_after date; v_off int;
begin
  perform assert_staff_or_service(p_tenant);

  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then
    raise exception 'That student does not belong to this academy.' using errcode = 'no_data_found';
  end if;
  select * into m from members where id = e.member_id;

  -- Deliberately not "must be paused". A student who simply stopped coming and
  -- reappears is the commonest shape of a break, and was never formally paused.
  -- Only a CLOSED enrolment is refused: reopening one is reenroll_member's job,
  -- because that opens a new row.
  if e.status = 'discontinued' then
    raise exception '% has left the academy — bringing them back starts a new enrolment.', m.name
      using errcode = 'check_violation';
  end if;
  if v_on > ist_today() then
    raise exception 'A return date cannot be in the future.' using errcode = 'check_violation';
  end if;

  -- An unconfirmed fee already carries a frozen window. Moving the anchor past
  -- it would make confirm_payment buy nothing at all, silently.
  if exists (select 1 from payments p
              where p.enrollment_id = e.id and p.status = 'pending_verification'
                and coalesce(p.months, 0) > 0) then
    raise exception 'There is a fee for % still waiting to be confirmed. Settle that first.', m.name
      using errcode = 'check_violation';
  end if;

  v_before := e.renewal_on;
  v_after  := greatest(coalesce(v_before, v_on), v_on);
  v_off    := greatest(v_on - coalesce(v_before, v_on), 0);

  update enrollments set status = 'active', renewal_on = v_after, updated_at = now()
   where id = e.id and tenant_id = p_tenant;

  -- The fact the money function reads. record_fee_payment anchors the FIRST fee
  -- after this date to it, then falls back to the chain.
  update members set rejoined_at = v_on, updated_at = now()
   where id = e.member_id and tenant_id = p_tenant;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id, 'system', 'Back after a break',
          nullif(coalesce(p_note, ''), ''),
          jsonb_build_object('resumed_on', v_on, 'renewal_on_before', v_before,
                             'renewal_on', v_after, 'days_written_off', v_off));

  return jsonb_build_object('status', 'active', 'resumed_on', v_on,
                            'renewal_on_before', v_before, 'renewal_on', v_after,
                            'days_written_off', v_off);
end $fn$;

-- The default grant is to PUBLIC; revoking anon alone is a no-op.
revoke execute on function public.pause_enrollment(text,bigint,date,text)  from public, anon;
revoke execute on function public.resume_enrollment(text,bigint,date,text) from public, anon;
grant  execute on function public.pause_enrollment(text,bigint,date,text)  to authenticated, service_role;
grant  execute on function public.resume_enrollment(text,bigint,date,text) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon','public.pause_enrollment(text,bigint,date,text)','execute')
  or has_function_privilege('anon','public.resume_enrollment(text,bigint,date,text)','execute') then
    raise exception 'anon can still execute the break functions';
  end if;
  if not has_function_privilege('authenticated','public.resume_enrollment(text,bigint,date,text)','execute') then
    raise exception 'staff cannot execute resume_enrollment';
  end if;
  raise notice 'break functions installed, anon locked out';
end $$;
