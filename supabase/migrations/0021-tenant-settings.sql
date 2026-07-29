-- ============================================================
-- 0021 · Let a tenant's own app read its own settings
-- scope: shared
--
-- `tenants` has no staff read policy, and it should not get one: the
-- row carries every tenant's config, and a policy is one predicate
-- mistake away from showing all of them. But a tenant app legitimately
-- needs its own billing details — the per-batch UPI ids go into the
-- reminder message a parent receives.
--
-- So: a SECURITY DEFINER accessor that returns ONE tenant's settings,
-- guarded, and only the keys a client has business seeing. Not the
-- whole config blob — `api_key` lives on that table, and rates and
-- payout rules are nobody's business at the till.
-- ============================================================

create or replace function public.tenant_settings(p_tenant text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare c jsonb;
begin
  perform assert_staff_or_service(p_tenant);

  select config into c from tenants where id = p_tenant;
  if c is null then
    return jsonb_build_object('brand', null);
  end if;

  -- An allowlist, not a redaction list. A new key added to config
  -- tomorrow stays private until somebody decides otherwise, which is
  -- the direction that default should fail in.
  return jsonb_build_object(
    'brand',   c ->> 'brand',
    'tagline', c ->> 'tagline',
    'city',    c ->> 'city',
    'venues',  c -> 'venues',
    'billing', jsonb_build_object(
      'payee',      c #> '{billing,payee}',
      'upiIds',     c #> '{billing,upiIds}',
      'upiByBatch', c #> '{billing,upiByBatch}'
    ),
    'features', c -> 'features'
  );
end $function$;

comment on function public.tenant_settings(text) is
  'One tenant''s own client-safe settings. Allowlisted; never returns api_key or rates.';

revoke execute on function public.tenant_settings(text) from public, anon;
grant execute on function public.tenant_settings(text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove the allowlist holds and the guard bites.
-- ------------------------------------------------------------
do $$
declare s jsonb;
begin
  s := tenant_settings('mpp');
  if s #>> '{billing,upiByBatch,kids-batch-a,upi}' is null then
    raise exception 'per-batch upi missing from tenant_settings';
  end if;
  if s ? 'api_key' or s ? 'rates' or s ? 'modules' then
    raise exception 'tenant_settings leaked a private key: %', s;
  end if;
  raise notice 'tenant_settings ok';
end $$;
