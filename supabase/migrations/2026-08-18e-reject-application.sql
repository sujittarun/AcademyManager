-- ============================================================
-- 2026-08-18e · reject_application() — the other half of the admissions
--               queue
-- scope: shared
--
-- WHY THIS IS NEEDED AT ALL
-- A family submits through the public form, the row lands in applications
-- with status 'pending', and staff can SEE it (applications_staff_r) —
-- but there is NO UPDATE POLICY on the table. So an application can be
-- approved (approve_application is SECURITY DEFINER and goes around RLS)
-- and it can be read, and it can never be declined. The only way to clear
-- one was to approve a family the academy had decided not to take.
--
-- IT DOES NOT DELETE. The row is marked, not removed, because:
--   · a rejected enquiry is still the record of someone who asked, and
--     "did we ever reply to that family" is a real question;
--   · the per-phone rate limit counts rows, so deleting one silently
--     hands the same phone another attempt;
--   · this platform has already destroyed a child's details with a raw
--     DELETE behind a reject button once. Not twice.
--
-- IT IS IDEMPOTENT AND IT REFUSES TO UNDO AN APPROVAL. Rejecting an
-- application that has already become a member would leave the member and
-- the enrolment in place while the paperwork says "declined" — a
-- disagreement between two tables that nothing would ever reconcile.
-- ============================================================

create or replace function public.reject_application(
  p_tenant      text,
  p_application bigint,
  p_by          text default null,
  p_reason      text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare a applications;
begin
  perform assert_staff(p_tenant);

  select * into a from applications
   where id = p_application and tenant_id = p_tenant;
  if a.id is null then
    raise exception 'No such application.';
  end if;

  if a.member_id is not null then
    raise exception 'That application was already approved — % is a member now.', a.name;
  end if;

  if a.status = 'rejected' then
    -- Already done. Say so calmly rather than erroring: two operators
    -- clearing the same queue should not produce a scary message.
    return jsonb_build_object('ok', true, 'id', a.id, 'already', true);
  end if;

  update applications
     set status       = 'rejected',
         reviewed_at  = now(),
         reviewed_by  = nullif(trim(coalesce(p_by, '')), ''),
         review_notes = nullif(trim(coalesce(p_reason, '')), '')
   where id = p_application and tenant_id = p_tenant;

  return jsonb_build_object('ok', true, 'id', a.id, 'already', false);
end
$function$;

revoke execute on function public.reject_application(text, bigint, text, text) from public, anon;
grant  execute on function public.reject_application(text, bigint, text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it. This block WRITES, so it cleans up after itself in the same
-- block — on a real apply the transaction commits, and a migration that
-- leaves test rows behind has happened here before (2026-08-17d left
-- seven fake admissions across two tenants).
-- ------------------------------------------------------------
do $$
declare v_id bigint; r jsonb; a applications;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);

  v_id := (submit_application(
            p_tenant => 'ska', p_name => 'ZZ Reject Probe',
            p_phone => '9000000971')->>'id')::bigint;

  r := reject_application('ska', v_id, 'probe', 'not this season');
  if not (r->>'ok')::boolean or (r->>'already')::boolean then
    raise exception 'first reject did not take: %', r;
  end if;

  select * into a from applications where id = v_id;
  if a.status <> 'rejected'       then raise exception 'status is %', a.status; end if;
  if a.reviewed_at is null        then raise exception 'reviewed_at not set'; end if;
  if a.reviewed_by <> 'probe'     then raise exception 'reviewed_by is %', a.reviewed_by; end if;
  if a.review_notes is null       then raise exception 'reason not stored'; end if;
  if a.member_id is not null      then raise exception 'reject created a member'; end if;

  -- Second call is a no-op, not an error.
  r := reject_application('ska', v_id, 'probe', null);
  if not (r->>'already')::boolean then raise exception 'second reject was not idempotent'; end if;

  -- A staff member of another academy must not reach it.
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"demo"}}', true);
  begin
    perform reject_application('ska', v_id, 'demo staff', null);
    raise exception 'staff of demo rejected an ska application';
  exception when others then
    if sqlerrm <> 'not authorised' then raise; end if;
  end;

  -- ALWAYS clean up.
  delete from applications where tenant_id = 'ska' and id = v_id;
  if exists (select 1 from applications where id = v_id) then
    raise exception 'probe row survived';
  end if;
end $$;
