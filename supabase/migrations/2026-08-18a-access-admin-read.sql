-- ============================================================
-- 2026-08-18a · list_staff_access() — the read behind the console's
--               "People & access" panel
-- scope: shared
--
-- WHY A FUNCTION AND NOT A VIEW OR A TABLE READ:
-- the answer to "who can sign in to this academy?" lives in auth.users,
-- which no client role may read. Only the app_metadata claims on an auth
-- user decide access; staff_scopes records the CENTRES a coach may reach
-- but grants nothing by itself. So the panel needs an elevated read, and
-- an elevated read needs a guard.
--
-- WHAT I GOT WRONG BEFORE WRITING THIS, recorded because the next person
-- will be tempted the same way:
-- I had planned to widen set_staff_scope() with a p_role argument so one
-- table could hold managers and coaches. staff_scopes has
--     CHECK (role = 'coach')
-- so it is coach-only ON PURPOSE. Widening it would have put managers in
-- the table that my_centres() and assert_attendance_access() read, which
-- is how a manager silently acquires a coach's centre scoping — or worse,
-- how a coach-shaped guard starts answering for a manager. The two roles
-- are stored differently and that is correct:
--
--     manager  = an auth user whose app_metadata says am_role=staff
--     coach    = the same, am_role=coach, PLUS a staff_scopes row that
--                names the centres they may take a register at
--
-- So set_staff_scope() is untouched, and this migration adds exactly one
-- read. The writes belong to the access-admin edge function, because
-- creating an auth user needs the service key and that may never sit in
-- a client.
-- ============================================================

create or replace function public.list_staff_access(p_tenant text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'auth'
as $function$
declare v_rows jsonb;
begin
  -- Operator, or a staff member of this academy looking at their own.
  -- assert_staff() also admits operator, and refuses a staff member of
  -- another tenant.
  perform assert_staff(p_tenant);

  select coalesce(jsonb_agg(x order by x->>'role', x->>'email'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
             'email',        u.email,
             'role',         u.raw_app_meta_data->>'am_role',
             'name',         coalesce(s.name, split_part(u.email, '@', 1)),
             'centre_ids',   coalesce(s.centre_ids, '{}'),
             'scope_active', s.active,
             'has_scope',    s.id is not null,
             -- A coach with no staff_scopes row can sign in and then reach
             -- nothing, because my_centres() returns empty. That reads as
             -- a broken app, so the panel must be able to show it.
             'needs_scope',  (u.raw_app_meta_data->>'am_role') = 'coach'
                             and (s.id is null or coalesce(array_length(s.centre_ids,1),0) = 0),
             'confirmed',    u.email_confirmed_at is not null,
             'banned',       u.banned_until is not null and u.banned_until > now(),
             'last_sign_in', u.last_sign_in_at,
             'created_at',   u.created_at
           ) as x
      from auth.users u
      left join staff_scopes s
        on s.tenant_id = p_tenant
       and lower(s.email) = lower(u.email)
     where u.raw_app_meta_data->>'tenant_id' = p_tenant
  ) t;

  return v_rows;
end
$function$;

-- Default-closed, then granted back deliberately. `revoke ... from anon`
-- alone is a no-op — the grant that matters is the bare =X/postgres that
-- CREATE hands to PUBLIC.
revoke execute on function public.list_staff_access(text) from public, anon;
grant  execute on function public.list_staff_access(text) to authenticated, service_role;

-- Assertions run under a REAL operator JWT. `set role postgres` does not
-- work here: auth_role() reads auth.jwt(), not the database role, so the
-- guard correctly refused it — which is itself worth knowing.
do $$
declare r jsonb;
begin
  -- Reads only; nothing to clean up. (A migration whose assertions WRITE
  -- commits those writes on the real apply — see PLATFORM.md.)
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"operator"}}', true);
  r := list_staff_access('ska');
  if jsonb_typeof(r) <> 'array' then
    raise exception 'list_staff_access did not return an array';
  end if;
  -- ska has no accounts yet, so this must be empty rather than erroring.
  if jsonb_array_length(r) <> 0 then
    raise exception 'expected 0 ska accounts, got %', jsonb_array_length(r);
  end if;
  -- raj genuinely has coaches; the function must see them.
  if jsonb_array_length(list_staff_access('raj')) < 1 then
    raise exception 'raj should have at least one account visible';
  end if;
end $$;
