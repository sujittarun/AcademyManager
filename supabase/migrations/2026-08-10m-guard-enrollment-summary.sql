-- ============================================================
-- 2026-08-10m · enrollment_payment_summary leaks across tenants
-- scope: shared
--
-- Found by external audit, confirmed behaviourally:
--
--   begin;
--   select set_config('request.jwt.claims',
--     '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}', true);
--   set local role authenticated;
--   select current_user, enrollment_payment_summary(1238);
--   rollback;
--
--   -> running_as = authenticated
--      {"paid_count":3,"paid_total":6600,"last_amount":2200,"last_on":"2026-07-03"}
--
-- Enrollment 1238 belongs to tenant `demo`. The caller was Raj's staff.
-- No guard fired.
--
-- This is the 0010 bug class, still present: a SECURITY DEFINER function
-- that takes an ENROLLMENT ID rather than a tenant. PLATFORM.md already
-- names it — "the ones that leaked hardest (enrollment_fee,
-- enrollment_payment_summary) take an enrollment id and no tenant at
-- all". enrollment_fee was fixed, because it calls resolve_fee() which
-- asserts. This one is pure SQL and never touches that path, so it was
-- left open.
--
-- Why the platform's own audits missed it: rpc_audit() looks for definer
-- functions ANON can execute. This one is closed to anon and open to
-- authenticated, which is a different question and nothing asks it.
--
-- The fix derives the tenant from the row and asserts against it, rather
-- than adding a p_tenant argument. An argument would be another thing a
-- caller can lie about; the enrollment already knows which academy it
-- belongs to.
-- ============================================================

create or replace function public.enrollment_payment_summary(p_enrollment bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_tenant text; v_out jsonb;
begin
  -- Derive the tenant from the row, then assert the caller belongs to it.
  -- Not a p_tenant argument: that is a naming convention, not a security
  -- property, and it is exactly what a caller would forge.
  select e.tenant_id into v_tenant from enrollments e where e.id = p_enrollment;
  if v_tenant is null then
    -- Say nothing about whether the id exists. A caller who can probe
    -- "does enrollment 1238 exist" can enumerate the platform.
    return jsonb_build_object('paid_count', 0, 'paid_total', 0,
                              'unverified', 0, 'unverified_count', 0,
                              'last_on', null, 'last_amount', null,
                              'last_months', null, 'covered_to', null);
  end if;
  perform assert_staff_or_service(v_tenant);

  select jsonb_build_object(
           'paid_count',       count(*) filter (where p.status = 'paid'),
           'paid_total',       coalesce(sum(p.amount) filter (where p.status = 'paid'), 0),
           'unverified',       coalesce(sum(p.amount) filter (where p.status = 'pending_verification'), 0),
           'unverified_count', count(*) filter (where p.status = 'pending_verification'),
           'last_on',          max(p.on_date) filter (where p.status = 'paid'),
           'last_amount',      (array_agg(p.amount order by p.on_date desc nulls last)
                                  filter (where p.status = 'paid'))[1],
           'last_months',      (array_agg(p.months order by p.on_date desc nulls last)
                                  filter (where p.status = 'paid'))[1],
           'covered_to',       max(p.period_to) filter (where p.status = 'paid')
         )
    into v_out
    from payments p
   where p.enrollment_id = p_enrollment
     and p.tenant_id = v_tenant;   -- belt and braces: ids are global

  return coalesce(v_out, '{}'::jsonb);
end $$;

comment on function public.enrollment_payment_summary(bigint) is
  'Payment totals for one enrollment. Derives the tenant from the row and asserts the caller belongs to it — it takes no tenant argument, because an argument is something a caller can forge.';

revoke execute on function public.enrollment_payment_summary(bigint) from public, anon;
grant  execute on function public.enrollment_payment_summary(bigint) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks. The grant is not the guard here, so the test has to actually
-- become the role — `set local role` OUTSIDE a transaction is a no-op
-- and would pass regardless.
-- ------------------------------------------------------------
do $$
declare v_other bigint; v_own bigint; v jsonb;
begin
  select id into v_other from enrollments where tenant_id = 'demo' order by id limit 1;
  select id into v_own   from enrollments where tenant_id = 'raj'  order by id limit 1;
  if v_other is null or v_own is null then
    raise notice 'skipping behaviour test: need one demo and one raj enrollment';
    return;
  end if;

  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}', true);
  set local role authenticated;

  -- another tenant's enrollment must now be refused
  begin
    v := enrollment_payment_summary(v_other);
    reset role;
    raise exception 'raj staff still read demo enrollment % : %', v_other, v;
  exception
    when sqlstate '42501' then null;   -- assert_staff_or_service raised
    when others then
      if sqlerrm not ilike '%not authorised%' then
        reset role;
        raise exception 'unexpected error instead of a clean refusal: %', sqlerrm;
      end if;
  end;

  -- and its OWN tenant must still work, or the fix broke the app
  v := enrollment_payment_summary(v_own);
  reset role;
  if v is null then raise exception 'raj staff can no longer read their own enrollment'; end if;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'cross-tenant read refused; same-tenant read intact';
end $$;
