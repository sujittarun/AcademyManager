-- ============================================================
-- 2026-08-19o · tenant isolation stops depending on one settings row
-- scope: shared
--
-- WHAT WAS THERE
-- 36 policies across 12 tables — batches, centres, coaches, enrollments,
-- fee_rules, member_timeline, payout_rules, payouts, reminder_events,
-- sessions, sports, wa_flow_events — each ending
--
--     ... OR (NOT is_locked())
--
-- and two guards opening with
--
--     if not is_locked() then return; end if;
--
-- namely assert_staff(), which stands in front of record_fee_payment,
-- reminder_queue, compute_payouts and every other definer function, and
-- assert_attendance_access().
--
-- is_locked() reads exactly one row: platform_settings where key =
-- 'lockdown'. It is a development-era scaffold — schema.sql still
-- describes assert_staff as "a guard that only bites after lockdown is
-- enabled" — and it worked as intended. The problem is what it grew into.
--
-- WHY IT HAD TO GO
-- `lockdown` reads like an emergency mode somebody would switch OFF once
-- the emergency passed. It is the opposite: it is the only thing holding
-- the door shut. anon holds the full arwdDxt grant on all twelve tables,
-- so RLS is the entire barrier, and setting that one row to 'false' would
-- make every tenant's enrolments, fee rules, payouts, member timelines and
-- reminder history readable AND writable by anyone holding the anon key —
-- which is public by design and committed in all six tenant repos.
--
-- Nobody would flip it maliciously. Somebody would flip it tidying up.
--
-- WHY REMOVING IT IS SAFE TO DO TODAY
-- is_locked() currently returns true, so
--
--     X OR (NOT true)  ==  X OR false  ==  X
--     if not true then return          ==  never returns early
--
-- The branch is already dead. This migration is a provable no-op under the
-- present setting, and it proves it rather than asserting it: every count
-- visible to anon, to a Raj staff member and to an SKA staff member is
-- measured before the change and again after, and any difference aborts.
--
-- Then it does the test that is the whole point — sets lockdown to 'false'
-- inside this transaction, measures a third time, and requires the numbers
-- to be identical. Before today that flip would have opened everything.
--
-- THE LOCKDOWN ROW IS DELIBERATELY LEFT AT 'true'.
-- This removes the DEPENDENCY; it does not rely on the row being gone. If
-- some reference was missed, the row is still there holding that door. Two
-- locks, then one lock, is the right order; never zero.
--
-- WHAT CANNOT BE AFFECTED, CHECKED RATHER THAN ASSUMED
--   * service_role and postgres both carry rolbypassrls, so the operator
--     console, every pg_cron job and the edge functions never consult
--     these policies at all.
--   * the public timetable is served by SEPARATE policies —
--     centres_public_r / batches_public_r / sports_public_r, granted to
--     anon, reading (active AND tenant_publishes_timetable(tenant_id)).
--     Removing a dead branch from the *_staff_r policies cannot touch it.
--     That path has broken twice (0004, 0011) and is checked again below.
--   * the *_staff_d policies on these same tables are ALREADY in the shape
--     this migration moves the other three to. There is nothing new here;
--     twelve tables are being brought into line with their own DELETE rule.
--
-- WHAT IS DELIBERATELY NOT TOUCHED
--   * is_shared_object() and tenant_reach_audit() contain the STRING
--     'is_locked' in lists of object names. They are not escapes and
--     rewriting them would corrupt those lists.
--   * is_locked() keeps its grant to PUBLIC. 0011 restored it after
--     revoking it took Raj's timetable down, and although no policy calls
--     it after today, nothing is gained by re-testing that lesson.
-- ============================================================

-- ------------------------------------------------------------
-- The probe table. Dropped at commit, so it exists only for the life of
-- this migration.
-- ------------------------------------------------------------
create temp table _lockdown_probe (
  phase   text,
  seen_as text,
  tbl     text,
  n       bigint
) on commit drop;

-- ------------------------------------------------------------
-- The measurement. A function rather than a copied-and-pasted block,
-- because "before" and "after" have to be the SAME question asked twice —
-- two near-identical blocks is how they quietly stop being.
--
-- RLS is not applied to the migration's own role (postgres carries
-- rolbypassrls), so each pass must `set local role` to the role it is
-- speaking for. Counting as postgres would return every tenant's rows and
-- report a healthy system no matter what these policies said.
-- ------------------------------------------------------------
create or replace function public._lockdown_probe_take(p_phase text)
returns void
language plpgsql
as $function$
declare
  tbls text[] := array['batches','centres','coaches','enrollments','fee_rules',
                       'member_timeline','payout_rules','payouts','reminder_events',
                       'sessions','sports','wa_flow_events'];
  passes text[][] := array[
    array['anon',      'anon',          '{"role":"anon"}'],
    array['staff:raj', 'authenticated', '{"app_metadata":{"am_role":"staff","tenant_id":"raj"}}'],
    array['staff:ska', 'authenticated', '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}']
  ];
  cnts bigint[];
  t text; n bigint; i int; j int;
begin
  for j in 1 .. array_length(passes, 1) loop
    perform set_config('request.jwt.claims', passes[j][3], true);
    execute format('set local role %I', passes[j][2]);

    cnts := '{}';
    foreach t in array tbls loop
      /* A missing grant must read as a distinct value, not abort the
         run — "-1 before and -1 after" is still a valid comparison, and
         an aborted probe tells us nothing at all. */
      begin
        execute format('select count(*) from public.%I', t) into n;
      exception when others then
        n := -1;
      end;
      cnts := cnts || n;
    end loop;

    /* Back to the migration's own role before writing: the temp table
       belongs to the session user and anon may not insert into it. */
    reset role;
    for i in 1 .. array_length(tbls, 1) loop
      insert into _lockdown_probe values (p_phase, passes[j][1], tbls[i], cnts[i]);
    end loop;
  end loop;

  /* Leave no JWT behind. is_service() is true when the claim is EMPTY, so
     a staff claim left set would silently change how the rest of this
     transaction is authorised. */
  perform set_config('request.jwt.claims', '', true);
end
$function$;

select public._lockdown_probe_take('before');

-- ------------------------------------------------------------
-- THE CHANGE, part 1: the 36 policies.
--
-- ALTER, not DROP + CREATE. Altering rewrites only the expression and
-- cannot get the command or the role list wrong; recreating 36 policies
-- from a template can, and a policy recreated FOR ALL instead of FOR
-- SELECT is a silent widening on a table holding six academies' money.
--
-- Three shapes, verified to be the only three in the catalogue:
--   _r  select        operator OR (staff AND tenant) OR NOT is_locked()
--   _u  update using  (staff AND tenant) OR NOT is_locked()
--   _w  insert check  (staff AND tenant) OR NOT is_locked()
-- ------------------------------------------------------------
do $$
declare
  tbls text[] := array['batches','centres','coaches','enrollments','fee_rules',
                       'member_timeline','payout_rules','payouts','reminder_events',
                       'sessions','sports','wa_flow_events'];
  t text; n int;
begin
  foreach t in array tbls loop
    execute format(
      'alter policy %I on public.%I using ('
      || 'auth_role() = ''operator'' or (auth_role() = ''staff'' and tenant_id = auth_tenant()))',
      t || '_staff_r', t);

    execute format(
      'alter policy %I on public.%I using ('
      || 'auth_role() = ''staff'' and tenant_id = auth_tenant())',
      t || '_staff_u', t);

    execute format(
      'alter policy %I on public.%I with check ('
      || 'auth_role() = ''staff'' and tenant_id = auth_tenant())',
      t || '_staff_w', t);
  end loop;

  select count(*) into n
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where coalesce(pg_get_expr(p.polqual, p.polrelid), '') like '%is_locked%'
      or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') like '%is_locked%';
  if n <> 0 then
    raise exception '% policies still carry the lockdown escape', n;
  end if;
end $$;

-- ------------------------------------------------------------
-- THE CHANGE, part 2: the two guards.
--
-- Both are the live definition copied verbatim with exactly one line
-- removed. Reconstructing a guard from memory is how this platform once
-- shipped a fix that called the wrong helper; the rest of each body,
-- including assert_attendance_access's is_service() line and its coach
-- branch, is untouched.
-- ------------------------------------------------------------
create or replace function public.assert_staff(p_tenant text)
 returns void
 language plpgsql
 stable
 set search_path to 'public'
as $function$
begin
  if auth_role() = 'operator' then return; end if;
  if auth_role() = 'staff' and auth_tenant() = p_tenant then return; end if;
  raise exception 'not authorised';
end $function$;

create or replace function public.assert_attendance_access(p_tenant text, p_batch bigint)
 returns void
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_centre bigint; v_centres bigint[];
begin
  if is_service() then return; end if;
  if auth_role() = 'operator' then return; end if;
  if auth_role() = 'staff' and auth_tenant() = p_tenant then return; end if;

  if auth_role() = 'coach' and auth_tenant() = p_tenant then
    select centre_id into v_centre from batches
     where id = p_batch and tenant_id = p_tenant;
    if v_centre is null then raise exception 'batch not found'; end if;
    v_centres := my_centres(p_tenant);
    if v_centre = any(v_centres) then return; end if;
    raise exception 'You are not assigned to that centre.' using errcode = 'insufficient_privilege';
  end if;

  raise exception 'not authorised' using errcode = 'insufficient_privilege';
end $function$;

-- ------------------------------------------------------------
-- The canary, so this cannot come back quietly.
--
-- A shape check, and it has one known blind spot it is honest about:
-- tenant_reach_audit()'s source contains the words "revoking is_locked()"
-- in a comment explaining the 0011 outage, which no SQL-level match can
-- tell from a call. It is excluded by name.
-- ------------------------------------------------------------
create or replace function public.lockdown_escape_audit()
returns table(kind text, object text, detail text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select 'policy'::text,
         (c.relname || '.' || p.polname)::text,
         coalesce(pg_get_expr(p.polqual, p.polrelid),
                  pg_get_expr(p.polwithcheck, p.polrelid))::text
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where coalesce(pg_get_expr(p.polqual, p.polrelid), '') like '%is_locked%'
      or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') like '%is_locked%'
  union all
  select 'function'::text,
         (n.nspname || '.' || p.proname)::text,
         'body calls is_locked()'::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
   where l.lanname in ('plpgsql', 'sql')
     and p.prosrc ~ '\mis_locked\s*\('
     and p.proname not in ('is_locked', 'lockdown_escape_audit', 'tenant_reach_audit')
$function$;

revoke execute on function public.lockdown_escape_audit() from public, anon;
grant  execute on function public.lockdown_escape_audit() to authenticated, service_role;

comment on function public.is_locked() is
  'Reads platform_settings.lockdown. As of 2026-08-19o NOTHING depends on it: no policy names it and no guard calls it. It is kept, and the row is kept at true, only so that a missed reference would still be closed. Do not reintroduce it into a policy — lockdown_escape_audit() reports that hourly.';

-- ------------------------------------------------------------
-- The hourly job learns about it. Copied verbatim from the live
-- definition with one block appended, in the same shape as the block 0011
-- appended before it. An audit nobody runs is the thing this platform
-- keeps learning not to build.
-- ------------------------------------------------------------
create or replace function public.cron_health_check()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_gaps int; v_failed int; v_unscoped int; v_errs int; v_tenants text; v_rpc int; v_polfn int; v_lock int;
begin
  select count(*) into v_failed from sync_jobs where status='failed';
  select count(*) into v_gaps from (
    select 1 from bookings b
    join integrations i on i.tenant_id=b.tenant_id and i.enabled and i.channel<>b.source
    where b.date=current_date and b.status='confirmed' and b.court is not null
      and not exists (select 1 from sync_log sl where sl.tenant_id=b.tenant_id and sl.channel=i.channel
        and sl.action='push' and sl.status='ok'
        and sl.detail like '%'||b.court||'%'||current_date::text||'%'||b.hour||':00%')
  ) g;
  if v_gaps>0 or v_failed>0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','reconcile', case when v_failed>0 then 'error' else 'warn' end,
        v_gaps||' propagation gap(s), '||v_failed||' failed job(s)');
  end if;

  select count(*) into v_unscoped from rls_audit();
  if v_unscoped > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rls_audit','error',
        v_unscoped||' anon policy/policies with no tenant filter: '||
        (select string_agg(tbl||'.'||policy_name, ', ') from rls_audit()));
  end if;

  select count(*), string_agg(distinct tenant_id, ', ')
    into v_errs, v_tenants
    from platform_errors(1);
  if v_errs > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','client_errors','warn',
        v_errs||' distinct client error(s) in the last hour: '||coalesce(v_tenants,'?'));
  end if;

  if not events_flowing() then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','events_sink','error',
        'no events for 12h despite traffic in the past week — anon writes are likely broken');
  end if;

  select count(*) into v_rpc from rpc_audit();
  if v_rpc > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','rpc_audit','error',
        v_rpc||' definer function(s) executable by anon: '||
        (select string_agg(fn, ', ') from rpc_audit()));
  end if;

  -- appended by 0011: a policy that will silently deny because anon
  -- cannot execute a function its predicate calls
  select count(*) into v_polfn from policy_fn_audit();
  if v_polfn > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','policy_fn_audit','error',
        v_polfn||' policy function(s) anon cannot execute: '||
        (select string_agg(fn||' ('||used_by||')', ', ') from policy_fn_audit()));
  end if;

  -- appended by 2026-08-19o: tenant isolation must never again be one
  -- settings row away from being switched off
  select count(*) into v_lock from lockdown_escape_audit();
  if v_lock > 0 then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform','*','lockdown_escape','error',
        v_lock||' object(s) made tenant isolation conditional on platform_settings.lockdown again: '||
        (select string_agg(kind||' '||object, ', ') from lockdown_escape_audit()));
  end if;
end $function$;

select public._lockdown_probe_take('after');

-- ------------------------------------------------------------
-- Prove it. Three questions, in order of how much they matter.
-- ------------------------------------------------------------
do $$
declare
  r record; v_err text; v_n int; v_lock text;
begin
  -- 1. NOTHING MOVED. Every count, for every role, on every table.
  for r in
    select b.seen_as, b.tbl, b.n as before_n, a.n as after_n
      from _lockdown_probe b
      join _lockdown_probe a on a.seen_as = b.seen_as and a.tbl = b.tbl and a.phase = 'after'
     where b.phase = 'before' and b.n is distinct from a.n
  loop
    raise exception 'REGRESSION: % on % went from % rows to %',
      r.seen_as, r.tbl, r.before_n, r.after_n;
  end loop;

  -- 2. THE PRIVATE TABLES REALLY ARE PRIVATE to anon. A before/after
  --    comparison alone would happily agree that both were wide open.
  for r in
    select tbl, n from _lockdown_probe
     where phase = 'after' and seen_as = 'anon'
       and tbl not in ('centres','batches','sports')   -- the timetable three
       and n <> 0
  loop
    raise exception 'anon can see % rows of %', r.n, r.tbl;
  end loop;

  --    and the timetable Raj publishes still works. 0004 and 0011 both
  --    took it down; assert on content, never on "the query returned".
  select n into v_n from _lockdown_probe
   where phase = 'after' and seen_as = 'anon' and tbl = 'centres';
  if v_n < 1 then
    raise exception 'the public timetable is dark: anon sees % centres', v_n;
  end if;

  -- 3. A STAFF MEMBER SEES THEIR OWN ACADEMY AND ONLY THEIRS.
  for r in
    select p.seen_as, p.tbl, p.n as seen,
           split_part(p.seen_as, ':', 2) as who
      from _lockdown_probe p
     where p.phase = 'after' and p.seen_as like 'staff:%'
  loop
    execute format('select count(*) from public.%I where tenant_id = %L', r.tbl, r.who)
       into v_n;
    if r.seen <> v_n then
      raise exception '% sees % rows of % but that academy has %',
        r.seen_as, r.seen, r.tbl, v_n;
    end if;
  end loop;

  -- 4. THE GUARD still admits the right person and refuses the wrong one.
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  perform assert_staff('ska');
  begin
    perform assert_staff('leo');
    raise exception 'assert_staff let SKA staff act as Leo';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'not authorised' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- 5. THE POINT OF ALL THIS: flip lockdown off and nothing opens.
  --    Before today this single UPDATE published six academies.
  update platform_settings set value = 'false' where key = 'lockdown';
  if is_locked() then raise exception 'the flip did not take'; end if;

  perform public._lockdown_probe_take('unlocked');

  for r in
    select b.seen_as, b.tbl, b.n as locked_n, u.n as unlocked_n
      from _lockdown_probe b
      join _lockdown_probe u on u.seen_as = b.seen_as and u.tbl = b.tbl and u.phase = 'unlocked'
     where b.phase = 'after' and b.n is distinct from u.n
  loop
    raise exception 'LOCKDOWN STILL LOAD-BEARING: with it off, % sees % rows of % instead of %',
      r.seen_as, r.unlocked_n, r.tbl, r.locked_n;
  end loop;

  --    and the guard still bites with lockdown off, which is the line
  --    that used to be `if not is_locked() then return`
  perform set_config('request.jwt.claims', '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  begin
    perform assert_staff('leo');
    raise exception 'with lockdown off, assert_staff waved SKA staff into Leo';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'not authorised' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- PUT IT BACK. Two locks, then one lock — never zero.
  update platform_settings set value = 'true' where key = 'lockdown';
  if not is_locked() then
    raise exception 'lockdown was not restored';
  end if;

  -- 6. and nothing anywhere still depends on it
  select string_agg(kind || ' ' || object, ', ') into v_lock from lockdown_escape_audit();
  if v_lock is not null then
    raise exception 'the escape survives in: %', v_lock;
  end if;
end $$;

drop function public._lockdown_probe_take(text);
