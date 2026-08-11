-- ============================================================
-- 2026-08-12r · One duplicate index, and search_path on 18 of 20
-- scope: shared
--
-- Both from the Supabase advisors, and both smaller than they look —
-- with one deliberate refusal that matters more than either fix.
--
-- 1. A GENUINELY DUPLICATE INDEX.
--    public.reminder_events carries two identical btrees:
--        reminder_events_tenant_created_idx  (tenant_id, created_at DESC)
--        reminder_events_tenant_idx          (tenant_id, created_at DESC)
--    96 kB each, and the planner has been splitting scans between them
--    (163 and 526). One is pure write cost on every insert and update to
--    a table the reminder engine writes constantly. Dropping the
--    less-used one loses no capability: the survivor answers exactly the
--    same queries.
--
-- 2. search_path ON 18 FUNCTIONS, NOT 20.
--    The advisor flags 20 functions with a mutable search_path. Checked
--    first: NONE of them is SECURITY DEFINER. They all run as the
--    caller, so a hijacked search_path lets a user affect only their own
--    session — this is hygiene, not the privilege-escalation hole the
--    same lint describes on a definer function.
--
--    Two are excluded ON PURPOSE, and it is the most consequential
--    decision in this file:
--
--        public.auth_role()    referenced by 133 policies
--        public.auth_tenant()  referenced by 127 policies
--
--    Both are one-line `LANGUAGE sql STABLE` functions, which PostgreSQL
--    INLINES into the policy predicate. The planner refuses to inline a
--    function whose proconfig is set — so adding `SET search_path` here
--    would convert an inlined expression into a real function call on
--    every row of every RLS check on this platform. That is a
--    measurable, permanent slowdown for every tenant, bought with
--    nothing: both bodies are already schema-qualified (`auth.jwt()`),
--    and neither is a definer function.
--
--    Making the advisor go quiet is not worth making six academies
--    slower. If that lint has to be cleared later, the way to do it is
--    to inline the jwt expression directly into the policies and retire
--    the helpers — not to bolt a SET clause onto them.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO. The performance advisor also
-- lists 47 unindexed foreign keys. The largest table on this platform is
-- attendance_records at 5,117 rows and the whole database is a few
-- megabytes; below roughly a hundred thousand rows an index scan and a
-- sequential scan are indistinguishable, while every added index is a
-- real cost on every write — and 2026-08-12p just widened WAL on eight
-- tables with REPLICA IDENTITY FULL. Those 47 are advice calibrated for
-- large tables. Revisit them when a table crosses six figures, not
-- because a linter counted them.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The duplicate
-- ------------------------------------------------------------
drop index if exists public.reminder_events_tenant_created_idx;

-- ------------------------------------------------------------
-- 2. search_path, everywhere it costs nothing
-- ------------------------------------------------------------
do $$
declare r record; n int := 0;
begin
  for r in
    select p.oid,
           n.nspname || '.' || p.proname || '(' ||
             pg_get_function_identity_arguments(p.oid) || ')' as sig,
           n.nspname as sch
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where p.prokind = 'f'
       and p.proconfig is null
       and n.nspname in ('public','genalpha')
       and p.proname in (
         'demo_ladder_offset','is_valid_upi','touch_admission_intake_updated_at',
         'assert_staff','slot_rate','court_count','payout_slab_value','ist_today',
         'is_service','fee_rule_rank','touch_updated_at','slugify','distinct_count',
         'current_actor','whatsapp_platform_number','attendance_absence_streak',
         'normalize_admission_intake_slot','whatsapp_flow_event_title')
  loop
    -- genalpha functions need their own schema on the path as well as
    -- public; everything else resolves against public alone.
    execute format('alter function %s set search_path = %s',
                   r.sig,
                   case when r.sch = 'genalpha' then 'genalpha, public' else 'public' end);
    n := n + 1;
  end loop;
  raise notice 'pinned search_path on % functions', n;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  -- the duplicate is gone and the survivor remains
  if exists (select 1 from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
              where ns.nspname='public' and c.relname='reminder_events_tenant_created_idx') then
    raise exception 'the duplicate index is still there';
  end if;
  if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
                  where ns.nspname='public' and c.relname='reminder_events_tenant_idx') then
    raise exception 'the surviving index was dropped instead';
  end if;

  -- the 18 are pinned
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname in ('public','genalpha') and p.prokind='f' and p.proconfig is null
     and p.proname in (
       'demo_ladder_offset','is_valid_upi','touch_admission_intake_updated_at',
       'assert_staff','slot_rate','court_count','payout_slab_value','ist_today',
       'is_service','fee_rule_rank','touch_updated_at','slugify','distinct_count',
       'current_actor','whatsapp_platform_number','attendance_absence_streak',
       'normalize_admission_intake_slot','whatsapp_flow_event_title');
  if n > 0 then raise exception '% of the 18 still have a mutable search_path', n; end if;

  -- and the two that must stay inlinable are untouched
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname in ('auth_role','auth_tenant')
     and p.proconfig is not null;
  if n > 0 then
    raise exception 'auth_role/auth_tenant got a SET clause — they can no longer be inlined into 133 policies';
  end if;

  -- RLS still behaves after touching assert_staff and friends
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','staff','tenant_id','raj'))::text, true);
  perform set_config('role','authenticated', true);
  select count(*) into n from members where tenant_id <> 'raj';
  reset role;
  perform set_config('request.jwt.claims', null, true);
  if n > 0 then raise exception 'RLS broke: raj staff can see % other-tenant members', n; end if;

  raise notice 'duplicate index dropped, 18 search_paths pinned, RLS intact';
end $$;
