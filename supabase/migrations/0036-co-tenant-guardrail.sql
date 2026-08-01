-- ============================================================
-- 0036 · Guardrail: memories / push_subscriptions are NOT ours
-- scope: shared
--
-- They belong to Suhas's Remembering App — a family side project that
-- shares this Supabase project only because the free-project quota ran
-- out. Closed to anon by 0033; watched by anon_probe() since 0035.
--
-- This migration changes no behaviour. It stamps the facts onto the
-- tables themselves, so anyone who meets them in the catalogue —
-- a future session, a new tool, a curious grep — learns what they are
-- before touching them. The full rule lives in PLATFORM.md
-- ("Co-tenant, NOT a tenant: the Remembering App"): never platform
-- work, never dropped as cleanup, no upgrades, stays sealed.
-- ============================================================

do $$
begin
  if to_regclass('public.memories') is not null then
    comment on table public.memories is
      'NOT Academy Manager. Personal data of the Remembering App (family side project sharing this Supabase project). Sealed from anon by migration 0033; anon_probe() verifies hourly. Do not migrate, model, export, or drop as platform work — see PLATFORM.md "Co-tenant, NOT a tenant".';
  end if;
  if to_regclass('public.push_subscriptions') is not null then
    comment on table public.push_subscriptions is
      'NOT Academy Manager. Web Push credentials of the Remembering App (family side project sharing this Supabase project). Sealed from anon by migration 0033; anon_probe() verifies hourly. Do not migrate, model, export, or drop as platform work — see PLATFORM.md "Co-tenant, NOT a tenant".';
  end if;
end $$;
