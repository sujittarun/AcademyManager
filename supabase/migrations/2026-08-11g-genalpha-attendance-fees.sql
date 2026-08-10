-- ============================================================
-- 2026-08-11g · GenAlpha attendance into the session model, and its fees
-- scope: shared
--
-- Replaces two migrations that applied as ZERO-BYTE FILES. They were
-- generated with sed from originals that no longer exist on disk — the
-- history rewrite that purged the data-bearing migrations took them too.
-- sed wrote nothing, the runner applied nothing, and both were recorded
-- as successes. A migration runner cannot tell an empty file from a
-- no-op, so 2026-08-11f and -11e are ledgered and did nothing. This does
-- the work.
--
-- ATTENDANCE. All 1,477 rows are in the flat `attendance` table, where
-- shared_fn_coverage() calls them BLIND: attendance_roster/_history/
-- _dashboard read sessions + attendance_records and never look at it.
-- The flat table means footfall — right for Leo, a court venue with no
-- enrolments; wrong for a coaching academy that now has batches.
--
-- FEES. reminder_queue('genalpha') currently blocks six families on
-- fee_not_set: the payments moved but not the RULES, so resolve_fee()
-- has nothing to resolve. GenAlpha prices per student, which is exactly
-- what the member level of the 7-level chain is for.
-- ============================================================

-- 1. sessions: one per (batch, date) anyone attended
insert into sessions (tenant_id, batch_id, on_date, status)
select distinct 'genalpha', e.batch_id, a.date, 'held'
  from attendance a
  join genalpha.student_details d on d.legacy_uuid = a.person_id::uuid
  join enrollments e on e.member_id = d.member_id and e.tenant_id = 'genalpha'
 where a.tenant_id = 'genalpha' and a.kind = 'member' and e.batch_id is not null
on conflict do nothing;

-- 2. the child, in that session
insert into attendance_records (tenant_id, session_id, enrollment_id, status, marked_at)
select 'genalpha', s.id, e.id, 'present', (a.date + time '18:00')
  from attendance a
  join genalpha.student_details d on d.legacy_uuid = a.person_id::uuid
  join enrollments e on e.member_id = d.member_id and e.tenant_id = 'genalpha'
  join sessions s on s.tenant_id='genalpha' and s.batch_id=e.batch_id and s.on_date=a.date
 where a.tenant_id = 'genalpha' and a.kind = 'member'
on conflict do nothing;

-- 3. remove the flat duplicates. tenant_id in the WHERE: ids are global.
delete from attendance where tenant_id = 'genalpha' and kind = 'member';

-- 4. the fee chain. A tenant default underneath, then one member-level
--    rule per student carrying the fee GenAlpha actually charges them.
insert into fee_rules (tenant_id, label, monthly_amount, admission_fee, active, effective_from)
select 'genalpha', 'Academy default', 3500, 500, true, current_date - 730
 where not exists (select 1 from fee_rules
                    where tenant_id='genalpha' and member_id is null and batch_id is null
                      and centre_id is null and sport is null);

insert into fee_rules (tenant_id, label, member_id, monthly_amount, admission_fee,
                       active, effective_from)
select 'genalpha', 'Student fee · ' || m.name, m.id,
       d.coaching_fee::numeric, coalesce(d.admission_fee, 500)::numeric,
       true, coalesce(m.joined, current_date - 730)
  from genalpha.student_details d
  join members m on m.id = d.member_id
 where d.coaching_fee is not null and d.coaching_fee > 0
   and not exists (select 1 from fee_rules f where f.tenant_id='genalpha' and f.member_id=m.id);

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n_rec int; n_flat int; n_blind int; n_blocked int; v_src text;
begin
  select count(*) into n_rec  from attendance_records where tenant_id='genalpha';
  select count(*) into n_flat from attendance         where tenant_id='genalpha';
  if n_rec <> 1477 then
    raise exception 'expected 1477 attendance_records, got % — attendance was LOST', n_rec;
  end if;
  if n_flat <> 0 then raise exception '% flat rows survive and will double-count', n_flat; end if;

  select count(*) into n_blind from shared_fn_coverage()
   where tenant_id='genalpha' and verdict='BLIND';
  if n_blind > 0 then raise exception '% BLIND surfaces remain for genalpha', n_blind; end if;

  -- every active enrolment resolves to a real amount
  if exists (select 1 from enrollments e where e.tenant_id='genalpha' and e.status='active'
               and coalesce((resolve_fee('genalpha', e.member_id, e.centre_id, e.sport,
                                         e.batch_id, 1, null)->>'amount')::numeric,0) <= 0) then
    raise exception 'an active genalpha enrolment still resolves to no fee';
  end if;

  -- and it resolves at the MEMBER level, not falling through to the default
  select (resolve_fee('genalpha', e.member_id, e.centre_id, e.sport, e.batch_id, 1, null)->>'source')
    into v_src
    from enrollments e join genalpha.student_details d on d.member_id = e.member_id
   where e.tenant_id='genalpha' and e.status='active' and d.coaching_fee > 0 limit 1;
  if v_src is distinct from 'member' then
    raise exception 'fee chain resolved at % for a student with an explicit fee', coalesce(v_src,'<null>');
  end if;

  select count(*) into n_blocked from reminder_queue('genalpha') where blocked_reason='fee_not_set';
  if n_blocked > 0 then raise exception '% reminders still blocked on fee_not_set', n_blocked; end if;

  if (select count(*) from cross_tenant_integrity()) <> 0 then
    raise exception 'cross_tenant_integrity() is non-empty';
  end if;

  raise notice 'attendance in the session model, fee chain resolving, nothing blind or blocked';
end $$;
