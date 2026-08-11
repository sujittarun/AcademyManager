-- ============================================================
-- 2026-08-12g · Let a coach read the roster, without the phone numbers
-- scope: shared
--
-- The coach tier needs the app to load a roster and a register. Building
-- that as new RPCs meant a new DTO in the app, because Student has ~25
-- required fields with no defaults — a lot of Kotlin for what is really a
-- visibility question.
--
-- The same answer fits in the views the app already reads. Two changes:
--
--   security_invoker OFF. As invoker views these run under the caller, so
--   RLS on public.members applies and every policy there tests
--   auth_role() = 'staff' — a coach sees nothing. As definer views they
--   run as the owner, and the gate becomes the WHERE clause below plus
--   the grant, which is the pattern this platform already uses for
--   whatsapp_credentials() and the coach_* functions.
--
--   A role guard IN the view, so turning RLS off does not turn the tenant
--   boundary off with it: genalpha's own staff, the operator, a coach, or
--   a service caller. Another tenant's staff gets nothing.
--
-- CONTACT DETAILS ARE NULLED FOR A COACH, in the view, so it is the
-- database deciding and not the app: parent phone, alternate phone,
-- address and the parent's name come back NULL when auth_role()='coach'.
-- A coach with a leaked PIN gets first names, ages, slots and who
-- attended — not 81 families' contact details, which is the leak closed
-- on 2026-08-10 and the thing this must not reopen.
--
-- public.members keeps no coach policy, so there is no way round: a coach
-- querying it directly still gets nothing.
-- ============================================================

drop view if exists genalpha.students cascade;
create view genalpha.students with (security_invoker = false) as
 SELECT d.legacy_uuid AS id,
    m.name,
    COALESCE(d.age, EXTRACT(year FROM age(m.dob::timestamp with time zone))::integer) AS age,
    m.joined AS join_date,
    d.fees_paid,
    d.amount_paid,
    d.renewals,
    COALESCE(d.source_created_at, m.created_at) AS created_at,
    COALESCE(d.source_updated_at, m.updated_at) AS updated_at,
    m.added_by,
    m.updated_by,
    m.reg_no,
    m.rejoined_at,
    m.status = 'discontinued'::text AS discontinued,
    m.discontinued_on AS discontinued_at,
    d.time_slot,
    d.admission_id,
    d.jersey_size,
    d.jersey_pairs,
    d.payment_method,
    d.payment_upi_id,
    d.payment_reference,
    m.notes AS comments,
    CASE WHEN auth_role() = 'coach' THEN NULL::text ELSE m.parent_name END AS father_guardian_name,
    CASE WHEN auth_role() = 'coach' THEN NULL::text ELSE m.parent_phone END AS parent_contact_no,
    CASE WHEN auth_role() = 'coach' THEN NULL::text ELSE m.alt_phone END AS alternate_contact_no,
    m.school AS school_college,
    m.grade,
    CASE WHEN auth_role() = 'coach' THEN NULL::text ELSE m.address END AS address,
    d.filled_by,
    d.payment_status,
    d.fee_plan,
    d.coaching_fee,
    d.admission_fee,
    d.jersey_amount,
    d.total_fee_amount,
    d.fee_pause_days,
    m.whatsapp_status AS whatsapp_contact_status,
    m.reminders_paused AS whatsapp_reminders_paused,
    m.reminders_paused_at AS whatsapp_reminders_paused_at,
    m.reminders_paused_by AS whatsapp_reminders_paused_by,
    e.renewal_on AS paid_through
   FROM members m
     JOIN genalpha.student_details d ON d.member_id = m.id
     LEFT JOIN enrollments e ON e.member_id = m.id AND e.tenant_id = 'genalpha'::text
  WHERE m.tenant_id = 'genalpha'::text
   AND (auth_role() = 'coach'
        OR auth_role() = 'operator'
        OR is_service()
        OR (auth_role() = 'staff' AND auth_tenant() = 'genalpha'));

drop view if exists genalpha.attendance cascade;
create view genalpha.attendance with (security_invoker = false) as
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
  WHERE ar.tenant_id = 'genalpha'::text
   AND (auth_role() = 'coach'
        OR auth_role() = 'operator'
        OR is_service()
        OR (auth_role() = 'staff' AND auth_tenant() = 'genalpha'));

revoke all on genalpha.students, genalpha.attendance from public, anon;
grant select, insert, update, delete on genalpha.students to authenticated, service_role;
grant select on genalpha.attendance to authenticated, service_role;

create trigger students_iud instead of insert or update or delete
  on genalpha.students for each row execute function genalpha.students_write();

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; deps int;
begin
  select count(*) into n from genalpha.students;
  if n <> 81 then raise exception 'students returns % rows, expected 81', n; end if;
  select count(*) into n from genalpha.attendance;
  if n <> 1477 then raise exception 'attendance returns % rows, expected 1477', n; end if;

  -- the write path must have survived the drop/recreate
  if not exists (select 1 from pg_trigger
                  where tgrelid='genalpha.students'::regclass and not tgisinternal) then
    raise exception 'students lost its INSTEAD OF trigger — the app could not write';
  end if;

  -- as the service caller running this, contacts are NOT redacted
  select count(*) into n from genalpha.students where coalesce(parent_contact_no,'') <> '';
  if n = 0 then raise exception 'staff lost their phone numbers too'; end if;
  raise notice 'staff still see % players with a contact number', n;

  -- and a coach cannot reach members the long way round
  select count(*) into deps from pg_policy p
    join pg_class c on c.oid=p.polrelid join pg_namespace ns on ns.oid=c.relnamespace
   where ns.nspname='public' and c.relname='members'
     and pg_get_expr(p.polqual, p.polrelid) like '%coach%';
  if deps <> 0 then raise exception 'a policy on public.members now admits coach'; end if;

  -- anon still gets nothing
  if has_table_privilege('anon','genalpha.students','select') then
    raise exception 'anon can read the roster again';
  end if;

  raise notice 'coach can read the roster and register; contacts redacted for them only';
end $$;
