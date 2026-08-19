-- ============================================================
-- 2026-08-19c · "Ask for an account" — a page a coach can be sent to
-- scope: shared
--
-- WHY THIS IS A REQUEST AND NOT A SIGN-UP
-- Open sign-up was turned OFF on this project today, deliberately: anyone
-- holding the public anon key could call /auth/v1/signup and mint an
-- account. The damage was bounded — a fresh account carries no am_role and
-- no tenant_id, so RLS shows it nothing — but they were still real rows in
-- auth.users that nobody asked for.
--
-- That leaves a real gap the owner asked to fill: something to SEND to a
-- new coach, rather than collecting their details over WhatsApp.
--
-- So this is a request, not an account. The person asks; an operator
-- approves; the account is then minted by access-admin exactly as before,
-- which is the one path that sets am_role and tenant_id and never handles
-- a password. Nothing here can create a login, and that is the point:
--
--     the page is public, the decision is not.
--
-- ROLE IS CONSTRAINED TO staff|coach. A request cannot ask to be an
-- operator — that would let a public form nominate someone for
-- platform-wide access across every academy.
-- ============================================================

create table if not exists public.staff_requests (
  id          bigserial primary key,
  tenant_id   text        not null,
  name        text        not null,
  email       text        not null,
  phone       text,
  role        text        not null default 'coach',
  note        text,
  status      text        not null default 'pending',
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by text,
  constraint staff_requests_role_ck   check (role   in ('staff', 'coach')),
  constraint staff_requests_status_ck check (status in ('pending', 'approved', 'declined'))
);

create index if not exists staff_requests_tenant_idx
  on public.staff_requests (tenant_id, status, created_at desc);

comment on table public.staff_requests is
  'Someone asking an academy for a login. NOT an account — approving one mints the real login through access-admin, which is the only path that sets am_role and tenant_id.';

-- ------------------------------------------------------------
-- RLS. anon writes ONLY through the function below; it has no policy of
-- its own here, so a direct POST to /rest/v1/staff_requests is refused.
-- ------------------------------------------------------------
alter table public.staff_requests enable row level security;
revoke all on public.staff_requests from public, anon;
grant select on public.staff_requests to authenticated;

drop policy if exists staff_requests_staff_r on public.staff_requests;
create policy staff_requests_staff_r on public.staff_requests
  for select to authenticated
  using (auth_role() = 'operator'
         or (auth_role() = 'staff' and auth_tenant() = tenant_id));

-- ------------------------------------------------------------
-- The one way in.
-- ------------------------------------------------------------
create or replace function public.request_staff_access(
  p_tenant text,
  p_name   text,
  p_email  text,
  p_role   text default 'coach',
  p_phone  text default null,
  p_note   text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_email text; v_role text; v_recent int; v_id bigint;
begin
  if not tenant_exists(p_tenant) then
    raise exception 'Unknown academy.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A name is required.';
  end if;

  v_email := lower(btrim(coalesce(p_email, '')));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That does not look like an email address.';
  end if;

  /* Never operator. A public form must not be able to nominate someone for
     access to every academy on the platform. */
  v_role := lower(btrim(coalesce(p_role, 'coach')));
  if v_role not in ('staff', 'coach') then v_role := 'coach'; end if;

  /* Scoped to the tenant AND the address, so one academy's traffic cannot
     throttle another's — the mistake 2026-08-17d had to repair in
     submit_application. */
  select count(*) into v_recent
    from staff_requests
   where tenant_id = p_tenant and email = v_email
     and created_at > now() - interval '1 hour';
  if v_recent >= 3 then
    raise exception 'That request is already with the academy. They will be in touch.';
  end if;

  insert into staff_requests (tenant_id, name, email, phone, role, note)
  values (p_tenant, btrim(p_name), v_email,
          nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), ''),
          v_role, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  /* Thin on purpose: an anonymous caller gets an acknowledgement, never
     the row, and never a hint about who else has asked. */
  return jsonb_build_object('ok', true);
end
$function$;

revoke execute on function public.request_staff_access(text, text, text, text, text, text) from public;
grant  execute on function public.request_staff_access(text, text, text, text, text, text)
  to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and clean up — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare v_err text; v_n int;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  -- an unknown academy is refused
  begin
    perform request_staff_access('nosuchtenant', 'ZZ Probe', 'zz@example.com');
    raise exception 'accepted an unknown academy';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'Unknown academy.' then raise; end if;
  end;

  -- a malformed address is refused
  begin
    perform request_staff_access('ska', 'ZZ Probe', 'not-an-email');
    raise exception 'accepted a malformed address';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That does not look%' then raise; end if;
  end;

  -- operator cannot be requested; it lands as coach
  perform request_staff_access('ska', 'ZZ Probe', 'zz.probe@example.com', 'operator');
  select count(*) into v_n from staff_requests
   where tenant_id = 'ska' and email = 'zz.probe@example.com' and role = 'coach';
  if v_n <> 1 then
    raise exception 'an operator request was not downgraded to coach';
  end if;

  -- the rate limit holds
  perform request_staff_access('ska', 'ZZ Probe', 'zz.probe@example.com');
  perform request_staff_access('ska', 'ZZ Probe', 'zz.probe@example.com');
  begin
    perform request_staff_access('ska', 'ZZ Probe', 'zz.probe@example.com');
    raise exception 'the rate limit did not hold';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That request is already%' then raise; end if;
  end;

  delete from staff_requests where tenant_id = 'ska' and email = 'zz.probe@example.com';
  if exists (select 1 from staff_requests where email = 'zz.probe@example.com') then
    raise exception 'probe rows survived';
  end if;
end $$;
