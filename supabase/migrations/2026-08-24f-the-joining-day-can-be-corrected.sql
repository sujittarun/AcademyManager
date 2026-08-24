-- ============================================================
-- 2026-08-24f · The joining day can be corrected
-- scope: shared
--
-- "as we are adding existing student they might have joined 2 months back...
--  we also need a way to edit already added student to change joining date"
--
-- joined_on was written once, from the client, and could never be changed. For
-- a school entering its existing roll that is wrong twice: the date is a guess
-- on the way in, and it is the thing most likely to need correcting after.
--
-- It is not a free-text field either. Until a fee has been taken, joined_on IS
-- the cycle anchor (2026-08-24d), so moving it moves when the family is chased
-- — which makes it a money rule, and money rules live here.
--
--   no fee taken yet  -> joined_on and renewal_on move together
--   a fee has landed  -> only joined_on moves. The cycle was bought and paid
--                        for from a particular day; correcting a biographical
--                        date must not silently re-bill anybody.
--
-- That split is the whole function. Everything else is a guard.
-- ============================================================

create or replace function public.set_joining_date(
  p_tenant text, p_enrollment bigint, p_on_date date)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  e enrollments; m members; v_paid int; v_ren date;
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

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id, 'system', 'Joining date corrected', null,
          jsonb_build_object('joined_on_before', e.joined_on, 'joined_on', p_on_date,
                             'renewal_on', v_ren, 'fees_taken', v_paid));

  return jsonb_build_object('joined_on', p_on_date, 'renewal_on', v_ren,
                            'fees_taken', v_paid, 'name', m.name);
end $fn$;

revoke execute on function public.set_joining_date(text,bigint,date) from public, anon;
grant  execute on function public.set_joining_date(text,bigint,date) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon','public.set_joining_date(text,bigint,date)','execute') then
    raise exception 'anon can execute set_joining_date';
  end if;
  if not has_function_privilege('authenticated','public.set_joining_date(text,bigint,date)','execute') then
    raise exception 'staff cannot execute set_joining_date';
  end if;
end $$;
