-- ============================================================
-- 2026-08-19f · review_staff_request() — close the loop on the join page
-- scope: shared
--
-- 2026-08-19c gave people a page to ask for a login and gave the operator
-- nothing to do about it: staff_requests has SELECT for staff and operator
-- and no UPDATE policy at all, so a request could be READ and never
-- resolved. The list would grow forever and the pending count would stop
-- meaning anything, which is the same failure as a panel that always says
-- "nothing to do" — it stops being read.
--
-- WHY A FUNCTION AND NOT AN UPDATE POLICY
-- An UPDATE policy on the table would let staff rewrite the name, the
-- email or the role of a request — the very fields the operator is about
-- to trust when they mint a login. This changes STATUS and nothing else,
-- and records who did it.
--
-- APPROVING HERE DOES NOT CREATE A LOGIN. Nothing in Postgres can: an
-- account needs the Admin API and lives behind access-admin. This marks
-- the request handled; the console creates the person separately. Keeping
-- those apart means a mis-click here cannot mint access.
-- ============================================================

create or replace function public.review_staff_request(
  p_tenant text,
  p_id     bigint,
  p_status text,
  p_by     text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_status text; r staff_requests;
begin
  perform assert_staff(p_tenant);

  v_status := lower(btrim(coalesce(p_status, '')));
  if v_status not in ('approved', 'declined', 'pending') then
    raise exception 'A request is approved, declined or pending.';
  end if;

  select * into r from staff_requests where id = p_id and tenant_id = p_tenant;
  if r.id is null then
    raise exception 'No such request.';
  end if;

  update staff_requests
     set status = v_status,
         reviewed_at = case when v_status = 'pending' then null else now() end,
         reviewed_by = case when v_status = 'pending' then null else p_by end
   where id = p_id and tenant_id = p_tenant;

  return jsonb_build_object('ok', true, 'id', p_id, 'status', v_status);
end
$function$;

revoke execute on function public.review_staff_request(text, bigint, text, text) from public, anon;
grant  execute on function public.review_staff_request(text, bigint, text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and clean up — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare v_id bigint; v_err text; v_status text;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);

  insert into staff_requests (tenant_id, name, email, role)
  values ('ska', 'ZZ Review Probe', 'zz.review@example.com', 'coach')
  returning id into v_id;

  -- a nonsense status is refused
  begin
    perform review_staff_request('ska', v_id, 'maybe');
    raise exception 'accepted a nonsense status';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'A request is approved%' then raise; end if;
  end;

  -- the good path stamps who and when
  perform review_staff_request('ska', v_id, 'declined', 'probe');
  select status into v_status from staff_requests where id = v_id;
  if v_status <> 'declined' then
    raise exception 'status is %, expected declined', v_status;
  end if;
  if (select reviewed_at from staff_requests where id = v_id) is null then
    raise exception 'reviewed_at was not stamped';
  end if;

  -- another academy's request is invisible, so it cannot be reviewed
  begin
    perform review_staff_request('leo', v_id, 'approved');
    raise exception 'reviewed a request as the wrong tenant';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'No such request%' and v_err not like '%not authorised%'
       and v_err not like '%staff%' then raise; end if;
  end;

  delete from staff_requests where id = v_id;
  if exists (select 1 from staff_requests where email = 'zz.review@example.com') then
    raise exception 'probe row survived';
  end if;
end $$;
