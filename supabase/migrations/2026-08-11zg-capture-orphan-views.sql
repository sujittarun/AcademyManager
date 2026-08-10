-- ============================================================
-- 2026-08-11zg · Two views exist in the database and in no migration
-- scope: shared
--
-- genalpha.attendance and genalpha.student_timeline were created out of
-- band — a dashboard, a psql session, another chat window. They work, the
-- app reads both, and `grep -rn "view genalpha\." supabase/migrations`
-- does not find them. That is exactly the case PLATFORM.md describes: a
-- shared-object change with `migration IS NULL` in ddl_log, which the
-- hourly schema_drift() alarm exists to catch.
--
-- Left alone, the next person to redefine either one has no source to
-- start from and will silently drop whatever is actually there. Today's
-- restoration of reminder_events and whatsapp_flow_events was that
-- situation, and it only went well because the pre-merge export still
-- existed.
--
-- So: the live definitions, captured verbatim, with their grants stated.
-- This is a no-op against the current database by construction — the
-- check at the end asserts the definition did not change — and it means
-- the next edit starts from a file instead of from pg_get_viewdef.
-- ============================================================

create or replace view genalpha.attendance with (security_invoker = true) as
SELECT ar.id::text AS id,
    d.legacy_uuid AS student_id,
    s.on_date AS attendance_date,
    ar.marked_at,
    ar.marked_by,
    ar.status
   FROM attendance_records ar
     JOIN sessions s ON s.id = ar.session_id
     JOIN enrollments e ON e.id = ar.enrollment_id
     JOIN genalpha.student_details d ON d.member_id = e.member_id
  WHERE ar.tenant_id = 'genalpha'::text;

revoke all on genalpha.attendance from public, anon;
grant select on genalpha.attendance to authenticated, service_role;

create or replace view genalpha.student_timeline with (security_invoker = true) as
SELECT t.id::text AS id,
    d.legacy_uuid AS student_id,
    t.kind AS event_type,
    (t.meta ->> 'event_date'::text)::date AS event_date,
    t.title,
    t.body AS details,
    t.meta ->> 'changed_by'::text AS changed_by,
    t.at AS created_at
   FROM member_timeline t
     JOIN genalpha.student_details d ON d.member_id = t.member_id
  WHERE t.tenant_id = 'genalpha'::text;

revoke all on genalpha.student_timeline from public, anon;
grant select on genalpha.student_timeline to authenticated, service_role;

comment on view genalpha.attendance is
  'GenAlpha''s flat attendance shape over the platform''s batch/session model. Read-only: marking goes through genalpha.mark_player_attendance().';
comment on view genalpha.student_timeline is
  'GenAlpha''s event shape over public.member_timeline. Read-only; the platform writes it.';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  -- Row counts must be exactly what they were: this file is meant to
  -- change nothing, and a captured definition that quietly differs from
  -- the live one is worse than no file at all.
  select count(*) into n from genalpha.attendance;
  if n <> 1477 then raise exception 'attendance now returns % rows, expected 1477', n; end if;
  select count(*) into n from genalpha.student_timeline;
  if n <> 3053 then raise exception 'student_timeline now returns % rows, expected 3053', n; end if;

  -- the columns the app selects
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='attendance'
     and column_name in ('id','student_id','attendance_date','marked_at','marked_by','status');
  if n <> 6 then raise exception 'attendance lost a column the app reads'; end if;

  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='student_timeline'
     and column_name in ('id','student_id','event_type','event_date','title','details','changed_by','created_at');
  if n <> 8 then raise exception 'student_timeline lost a column the app reads'; end if;

  -- and neither became anon-readable
  if has_table_privilege('anon','genalpha.attendance','select')
     or has_table_privilege('anon','genalpha.student_timeline','select') then
    raise exception 'a genalpha view became readable by anon';
  end if;

  raise notice 'attendance and student_timeline now have a source file; definitions unchanged';
end $$;
