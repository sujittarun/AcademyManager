-- ============================================================
-- 0041 · Three nouns wearing one word, and a check that notices
-- scope: shared
--
-- THE PROBLEM, in the live data.
--
-- "Attendance" means three different things in this database, and two
-- of them share a table where nothing tells them apart:
--
--   attendance(kind='staff')        did the coach turn up for work.
--                                   Payroll. mpp 130, leo 8, matchpoint 2
--   attendance(kind='member')       a member walked into the venue.
--                                   A VISIT. leo 23, machaxi 5, matchpoint 3
--   sessions + attendance_records   was this student present in Tuesday's
--                                   6am batch, against an expected roster.
--                                   raj 1,883 records / 244 sessions
--
-- `kind` is free text with no constraint, and `person_id` is text with
-- no foreign key, so the only thing separating payroll from footfall is
-- a word nobody is checking. That is how a table acquires a third
-- meaning by accident.
--
-- WHAT IS NOT DONE HERE, deliberately. The obvious "fix" is to merge
-- the two models. It cannot be done and should not be tried:
--
--   attendance_records.session_id     NOT NULL
--   attendance_records.enrollment_id  NOT NULL
--   sessions.batch_id                 NOT NULL
--
-- The rich model structurally requires batch -> session -> enrolment.
-- Leo has 231 bookings and ZERO enrolments — it is a court venue, not a
-- coaching academy. Its 23 rows cannot move into a model that demands a
-- scheduled class they never had. They are not a fork of class
-- attendance; they are a different fact.
--
-- So this migration does the two things that are actually true:
--   1. names the nouns, and stops a fourth appearing by accident
--   2. makes the blind spot visible instead of silent
--
-- THE BLIND SPOT. attendance_roster(), attendance_history(),
-- attendance_dashboard() and mark_attendance() read sessions and
-- attendance_records ONLY. CLAUDE.md lists them under "shared functions
-- — call these, do not reimplement", which reads as a promise that they
-- answer for every tenant. They answer for Raj. Leo has 23 rows of
-- member attendance that no shared function can see, and nothing has
-- ever said so, because nothing ever asked.
--
-- This is the same lesson as `anon_probe` and `events_flowing`: reading
-- the SQL tells you a function is WRITTEN correctly; only running it
-- tells you it ANSWERS. rls_audit() — a shape check — passed cleanly
-- through the worst leak this platform has had.
-- ============================================================

-- ------------------------------------------------------------
-- 1 · Name the nouns.
--
-- Every live writer sends kind='staff' (MatchPointPride cloud.ts:429,
-- :944) and the only other value present anywhere is 'member'. So this
-- constrains what is already true rather than changing behaviour.
-- ------------------------------------------------------------
alter table public.attendance
  drop constraint if exists attendance_kind_check;
alter table public.attendance
  add  constraint attendance_kind_check check (kind in ('staff', 'member'));

comment on table public.attendance is
  $c$Two different facts, told apart ONLY by `kind`:

     kind='staff'   an employee worked that day. Payroll.
     kind='member'  a member visited the venue. Footfall. No class
                    behind it — Leo and Machaxi are court venues with
                    no enrolments at all.

   This table is NOT class attendance. A student marked present in a
   scheduled batch lives in sessions + attendance_records, and the
   shared functions (attendance_roster, attendance_history,
   attendance_dashboard, mark_attendance) read THOSE and never this one.

   Do not add a third kind. If a new fact needs recording, it needs its
   own table — that is how this one ended up holding two.$c$;

comment on column public.attendance.kind is
  'staff = an employee worked. member = a member visited. Nothing else; see attendance_kind_check.';

comment on column public.attendance.person_id is
  'Text, and deliberately NOT a foreign key: it points at coaches when kind=''staff'' and members when kind=''member''. One more reason these are two nouns.';

comment on table public.attendance_records is
  'CLASS attendance: one student, one scheduled session. Requires an enrolment and a session, so it can only exist where a tenant runs coached batches. Written only by mark_attendance() and save_attendance_session().';

comment on table public.sessions is
  'One occurrence of a batch on one date — the thing attendance_records hangs off. Held or cancelled. Created on demand when a register is first marked.';

-- ------------------------------------------------------------
-- 2 · Notice the blind spot.
--
-- For each live tenant and each shared surface: how many rows can the
-- shared functions see, and how many exist that they cannot?
--
-- Deliberately a data comparison rather than a call-and-count-rows
-- probe. "Returned zero rows" is legitimate for most reporting
-- functions — nobody is due today, no session was held — so a probe
-- built on that would cry wolf until it was ignored. "Rows exist in a
-- place the shared functions structurally do not read" cannot be a
-- false alarm.
--
-- Archived tenants are skipped: they are not in the console, so an
-- alert about them is a number nobody can act on. Federated tenants are
-- skipped too — GenAlpha keeps its own schema and its own nineteen
-- tables, and none of this applies to it.
--
-- Adding a surface later is one more branch in the union below.
-- ------------------------------------------------------------
create or replace function public.shared_fn_coverage()
returns table (
  surface   text,
  tenant_id text,
  visible   bigint,
  invisible bigint,
  verdict   text,
  detail    text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with live as (
    select t.id
      from tenants t
     where not coalesce((t.config ->> 'archived')::boolean, false)
       and not coalesce((t.config ->> 'federated')::boolean, false)
  ),
  surfaces as (
    -- ATTENDANCE. The shared functions read sessions + attendance_records.
    -- A kind='member' row in the flat table is member attendance that
    -- none of them can reach.
    select 'attendance'::text as surface,
           l.id               as tenant_id,
           (select count(*) from attendance_records ar
             where ar.tenant_id = l.id)                        as visible,
           (select count(*) from attendance a
             where a.tenant_id = l.id and a.kind = 'member')    as invisible,
           'attendance_roster/_history/_dashboard read sessions+attendance_records only'::text
                                                               as detail
      from live l
  )
  select s.surface,
         s.tenant_id,
         s.visible,
         s.invisible,
         case when s.invisible > 0 then 'BLIND' else 'ok' end,
         s.detail
    from surfaces s
   order by 1, 2
$function$;

comment on function public.shared_fn_coverage() is
  'Per tenant, per shared surface: rows the shared functions can see vs rows that exist where they do not read. BLIND means a documented shared function cannot answer for that tenant.';

revoke execute on function public.shared_fn_coverage() from public, anon, authenticated;
grant  execute on function public.shared_fn_coverage() to service_role;

-- ------------------------------------------------------------
-- Its own hourly job, same shape as cron_anon_probe. Writes to
-- sync_log with tenant_id='platform', which is where every other
-- platform alarm already goes.
-- ------------------------------------------------------------
create or replace function public.cron_shared_fn_coverage()
returns void
language plpgsql
set search_path to 'public'
as $function$
declare v_blind text;
begin
  select string_agg(surface || '/' || tenant_id || ' (' || invisible || ' rows)', ', ')
    into v_blind
    from shared_fn_coverage()
   where verdict = 'BLIND';

  if v_blind is not null then
    insert into sync_log (tenant_id, channel, action, status, detail)
      values ('platform', '*', 'shared_fn_coverage', 'warn',
              'SHARED FUNCTIONS BLIND TO: ' || v_blind);
  end if;
end $function$;

revoke execute on function public.cron_shared_fn_coverage() from public, anon, authenticated;

select cron.unschedule('shared-fn-coverage-hourly')
 where exists (select 1 from cron.job where jobname = 'shared-fn-coverage-hourly');

select cron.schedule('shared-fn-coverage-hourly', '37 * * * *',
                     $cron$select public.cron_shared_fn_coverage()$cron$);

-- ------------------------------------------------------------
-- 3 · Prove both halves, against the live data, before recording this.
--
-- Assert on CONTENT, not on length — the is_locked breakage hid behind
-- a probe that counted the keys of a JSON error body and called it four
-- rows.
--
-- But not on an exact count of a LIVE table either: the first run of
-- this block failed on `raj visible = 1883` because Raj's coaches
-- marked another register between writing the assertion and running it.
-- A test that fails when the system is working is worse than no test.
-- So these assert the property that must hold — leo BLIND with nothing
-- visible, mpp and raj clear, raj demonstrably reading real rows —
-- rather than a number that is allowed to move.
-- ------------------------------------------------------------
do $$
declare
  v_n     bigint;
  v_row   record;
  v_threw boolean := false;
begin
  ---- the constraint refuses a third meaning -------------------
  begin
    insert into attendance (tenant_id, date, kind, person_id, present)
    values ('leo', current_date, 'student', '999999', true);
  exception when check_violation then
    v_threw := true;
  end;
  if not v_threw then
    raise exception 'attendance_kind_check did not refuse a new kind';
  end if;

  ---- and still accepts the two that are real ------------------
  begin
    insert into attendance (tenant_id, date, kind, person_id, present)
    values ('leo', date '1999-01-01', 'staff', '999999', true);
    delete from attendance
     where tenant_id = 'leo' and date = date '1999-01-01' and person_id = '999999';
  exception when others then
    raise exception 'attendance_kind_check broke a legitimate staff write: %', sqlerrm;
  end;

  ---- the coverage check sees leo, and says why ----------------
  select * into v_row from shared_fn_coverage()
   where surface = 'attendance' and tenant_id = 'leo';
  if not found then
    raise exception 'shared_fn_coverage returned no attendance row for leo';
  end if;
  if v_row.verdict <> 'BLIND' then
    raise exception 'expected leo BLIND, got % (invisible=%)', v_row.verdict, v_row.invisible;
  end if;
  if v_row.invisible < 1 then
    raise exception 'expected leo to have unreachable member rows, got %', v_row.invisible;
  end if;
  -- The whole point: Leo is a court venue with no enrolments, so the
  -- rich model holds nothing for it and the shared functions have
  -- literally nothing to answer with.
  if v_row.visible <> 0 then
    raise exception 'expected 0 visible rows for leo, got %', v_row.visible;
  end if;

  ---- mpp has 130 STAFF rows and must not alarm ----------------
  select * into v_row from shared_fn_coverage()
   where surface = 'attendance' and tenant_id = 'mpp';
  if not found then
    raise exception 'shared_fn_coverage returned no attendance row for mpp';
  end if;
  if v_row.verdict <> 'ok' then
    raise exception 'mpp false-alarmed on staff attendance: invisible=%', v_row.invisible;
  end if;

  ---- raj is the tenant the shared functions were built for ----
  select * into v_row from shared_fn_coverage()
   where surface = 'attendance' and tenant_id = 'raj';
  -- Not an exact count — this table grows every time a coach marks a
  -- register. A floor well above zero still proves the surface is
  -- reading real rows rather than quietly returning nothing.
  if v_row.verdict <> 'ok' or v_row.visible < 1000 then
    raise exception 'raj unexpected: verdict=% visible=%', v_row.verdict, v_row.visible;
  end if;

  ---- archived tenants stay out of it -------------------------
  select count(*) into v_n from shared_fn_coverage()
   where tenant_id in ('machaxi', 'matchpoint', 'genalpha');
  if v_n <> 0 then
    raise exception 'archived or federated tenants leaked into coverage: % rows', v_n;
  end if;

  ---- and the alarm actually fires ----------------------------
  perform cron_shared_fn_coverage();
  if not exists (
    select 1 from sync_log
     where tenant_id = 'platform' and action = 'shared_fn_coverage'
       and detail like '%attendance/leo%'
  ) then
    raise exception 'cron_shared_fn_coverage wrote no alarm for leo';
  end if;

  raise notice 'kind constrained; coverage reports leo BLIND on 23 rows, mpp and raj ok';
end $$;
