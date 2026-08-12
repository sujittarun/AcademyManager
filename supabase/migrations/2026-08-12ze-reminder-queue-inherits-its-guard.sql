-- Record that reminder_queue's tenant scoping is INHERITED, not its own.
--
-- WHAT WAS ESTABLISHED, AND HOW
--
-- reminder_queue() is SECURITY DEFINER and returns member_name,
-- parent_name, phone and amount. Its body contains no authorisation at all:
-- no assert_*, no auth_role(), no auth_tenant(), not one `raise`. Read on
-- its own, it looks like a cross-tenant leak, and I said so.
--
-- It is not. Measured against a deliberately unguarded build of the
-- function, with a staff-of-demo JWT:
--
--     select count(*) from reminder_queue('raj', current_date)
--     -> ERROR: not authorised   (from assert_staff, via resolve_fee)
--
-- reminder_queue calls resolve_fee() and resolve_upi(), and both assert. The
-- scoping is real; it just lives one level down. tenant_reach_audit() was
-- right to pass it — that audit treats a function as guarded if it calls
-- something that asserts, which is exactly this case.
--
-- WHY THE COMMENT, AND NOT A GUARD
--
-- An explicit `perform assert_staff_or_service(p_tenant)` was written,
-- dry-run, behaviour-tested and mutation-tested. It was NOT applied:
-- reminder_queue is `language sql`, so adding an imperative guard means
-- converting it to plpgsql, which blocks inlining and predicate pushdown on
-- a hot money path that four un-updatable mobile clients call. That trade is
-- worth it against a live leak. Against defence-in-depth it is not.
--
-- The residual risk is real but small, and it is a documentation problem:
-- anyone who loosens resolve_fee() or resolve_upi() — to let a coach see a
-- fee, say — silently opens this function too, and no audit would flag it,
-- because the callee would still look guarded. So the warning goes where
-- that person will be standing.
--
-- Scope: shared. Comments only. No behaviour change, no grant change.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

comment on function public.reminder_queue(text, date) is
  'Who is due and for how much, plus the reminder ladder stage. '
  'TENANT SCOPING IS INHERITED, NOT LOCAL: this function contains no guard '
  'of its own — it is scoped only because it calls resolve_fee() and '
  'resolve_upi(), which assert_staff(). If you loosen either of those, you '
  'open this too, and it returns parent names and phone numbers. '
  'tenant_reach_audit() will not warn you, because it counts a guarded '
  'callee as a guard. Verified 2026-08-12 by calling an unguarded build as '
  'staff of another tenant: refused.';

comment on function
  public.resolve_fee(text, bigint, bigint, text, bigint, integer, numeric) is
  'The 7-level fee chain. NOTE: reminder_queue() has no tenant guard of its '
  'own and inherits its scoping from this function''s assert_staff(). Do not '
  'relax that guard without giving reminder_queue one of its own — it '
  'returns parent names and phone numbers.';

do $$
declare v_args text;
begin
  -- The resolve_fee comment above pins a specific signature. If it ever
  -- changes, this migration must be revisited rather than silently
  -- commenting the wrong function, so assert the signature exists.
  select pg_get_function_identity_arguments(p.oid) into v_args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'resolve_fee';
  if v_args is null then
    raise exception 'resolve_fee not found — the inherited-guard note is stale';
  end if;

  -- and the premise must still hold: reminder_queue must still CALL them,
  -- or the comment is describing protection that no longer exists.
  if not (pg_get_functiondef('public.reminder_queue(text,date)'::regprocedure)
          ~* 'resolve_fee') then
    raise exception
      'reminder_queue no longer calls resolve_fee — it may now be unguarded '
      'for real. Give it an explicit assert_staff_or_service(p_tenant).';
  end if;
  if not (pg_get_functiondef('public.reminder_queue(text,date)'::regprocedure)
          ~* 'resolve_upi') then
    raise exception 'reminder_queue no longer calls resolve_upi — re-check its scoping';
  end if;

  raise notice 'reminder_queue: inherited scoping recorded on both ends';
end $$;
