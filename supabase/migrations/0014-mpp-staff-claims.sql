-- ============================================================
-- 0014 · Give the Pride staff login its claims
-- scope: mpp
--
-- staff@matchpointpride.com was created in the dashboard and confirmed,
-- but with an empty app_metadata. Every RLS policy on this platform
-- reads exactly two claims:
--
--   auth_role()   = jwt -> app_metadata ->> 'am_role'
--   auth_tenant() = jwt -> app_metadata ->> 'tenant_id'
--
-- With neither set, the account signs in perfectly and then sees
-- nothing at all — every policy evaluates false and every table returns
-- zero rows. That failure looks exactly like "the app is broken", which
-- is why cloud.ts checks the claims itself and says which tenant the
-- login belongs to rather than showing an empty screen.
--
-- app_metadata and not user_metadata: a user can edit their own
-- user_metadata, so a claim kept there would let anyone with the login
-- promote themselves to another tenant. app_metadata is writable only
-- with the service role. That distinction is the whole reason these are
-- the claims the policies trust.
--
-- Merged rather than replaced, so anything Supabase keeps in there
-- (providers, provider) survives.
-- ============================================================

update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                         || jsonb_build_object('am_role', 'staff', 'tenant_id', 'mpp')
 where id = '8069a030-b022-4cad-800a-7b0144fdf2d7';

do $$
declare m jsonb;
begin
  select raw_app_meta_data into m from auth.users
   where id = '8069a030-b022-4cad-800a-7b0144fdf2d7';

  if m is null then
    raise exception 'user 8069a030-… not found — was it created in a different project?';
  end if;
  if m ->> 'am_role' <> 'staff' then
    raise exception 'am_role is % after the update', coalesce(m ->> 'am_role', 'null');
  end if;
  if m ->> 'tenant_id' <> 'mpp' then
    raise exception 'tenant_id is % after the update', coalesce(m ->> 'tenant_id', 'null');
  end if;

  -- and the tenant it names has to exist, or this is a login to nowhere
  if not public.tenant_exists('mpp') then
    raise exception 'tenant mpp does not exist';
  end if;

  raise notice 'staff@matchpointpride.com -> am_role=staff tenant_id=mpp';
end $$;
