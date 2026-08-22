-- ============================================================
-- 2026-08-22a · Clear Mezzo's sample data for go-live
-- scope: mezzo
--
-- NOT APPLIED AUTOMATICALLY. Run it on the day the client starts using
-- the app for real, and not before — the sample data is what makes the
-- app worth showing him in the first place.
--
-- WHY THIS IS NOT THE ONE-LINE DELETE THE ONBOARDING PROMPT PROMISES.
--
-- `delete from members where tenant_id='mezzo' and is_demo` does not do
-- the job here, and it fails quietly rather than loudly:
--
--   enrollments -> members    ON DELETE CASCADE   (so enrolments go)
--   payments    -> enrollments ON DELETE SET NULL  (so payments STAY,
--                                                   with a null enrolment)
--
-- 181 of Mezzo's 182 payments hang off sample students. Deleting the
-- students would leave every one of those rows in place with
-- enrollment_id = NULL — still summed by the Money tab, still counted in
-- the console's GMV. The academy would open on day one showing months of
-- revenue it never took, and nothing would look broken.
--
-- Expenses are worse in one way and easier in another: they have no
-- member link at all, so nothing cascades to them and all 28 survive any
-- member-based delete. They also carry no PII, so they can simply go.
--
-- ORDER MATTERS: children before parents, so nothing is ever orphaned
-- even for the duration of the transaction.
--
-- WHAT IS KEPT: the centre, every batch, every instrument, the fee rules
-- and the tenant config. Those are the academy's setup, not sample data
-- — deleting them would leave him with an app that cannot price a
-- student. As of 22 Aug that is 7 instruments and 10 batches (the two
-- original time windows plus eight day-pair patterns added by the tenant
-- chat), but the checks below deliberately do not name those numbers.
-- ============================================================

do $$
declare
  n_mem int; n_pay int; n_att int; n_ses int; n_exp int; n_enr int; n_tl int;
begin
  select count(*) into n_mem from members where tenant_id='mezzo' and is_demo;
  if n_mem = 0 then
    raise notice 'no sample students left; nothing to clear';
    return;
  end if;

  -- 1. payments belonging to sample students, BEFORE the enrolment that
  --    identifies them is cascaded away by the member delete
  with demo_enr as (
    select e.id from enrollments e join members m on m.id = e.member_id
     where e.tenant_id='mezzo' and m.is_demo
  )
  delete from payments p
   where p.tenant_id='mezzo' and p.enrollment_id in (select id from demo_enr);
  get diagnostics n_pay = row_count;

  -- 2. attendance, then the sessions that held it
  with demo_enr as (
    select e.id from enrollments e join members m on m.id = e.member_id
     where e.tenant_id='mezzo' and m.is_demo
  )
  delete from attendance_records ar
   where ar.tenant_id='mezzo' and ar.enrollment_id in (select id from demo_enr);
  get diagnostics n_att = row_count;

  delete from sessions s
   where s.tenant_id='mezzo'
     and not exists (select 1 from attendance_records ar where ar.session_id = s.id);
  get diagnostics n_ses = row_count;

  -- 3. anything else that names a sample student
  delete from reminder_events re
   where re.tenant_id='mezzo'
     and re.enrollment_id in (select e.id from enrollments e
                               join members m on m.id=e.member_id
                              where e.tenant_id='mezzo' and m.is_demo);
  delete from member_timeline mt
   where mt.tenant_id='mezzo'
     and mt.member_id in (select id from members where tenant_id='mezzo' and is_demo);
  get diagnostics n_tl = row_count;

  -- 4. the students themselves; enrolments cascade
  select count(*) into n_enr from enrollments e join members m on m.id=e.member_id
   where e.tenant_id='mezzo' and m.is_demo;
  delete from members where tenant_id='mezzo' and is_demo;

  -- 5. sample spending. No owner link, so nothing above would have
  --    touched it, and it carries no personal data.
  delete from expenses where tenant_id='mezzo';
  get diagnostics n_exp = row_count;

  raise notice 'cleared: % students, % enrolments, % payments, % attendance, % sessions, % timeline, % expenses',
    n_mem, n_enr, n_pay, n_att, n_ses, n_tl, n_exp;
end $$;

-- ------------------------------------------------------------
-- Checks — the point is that NOTHING is left summing to money
-- ------------------------------------------------------------
do $chk$
declare n int; v numeric;
begin
  select count(*) into n from members where tenant_id='mezzo' and is_demo;
  if n > 0 then raise exception '% sample students survived', n; end if;

  -- the orphan trap this file exists for
  select count(*) into n from payments where tenant_id='mezzo' and enrollment_id is null;
  if n > 0 then
    raise exception '% payments were orphaned rather than deleted — they would still show as revenue', n;
  end if;

  select coalesce(sum(amount),0) into v from payments where tenant_id='mezzo';
  raise notice 'money still on the books: rs %  (should be only genuinely real payments)', v;

  select count(*) into n from attendance_records ar
   where ar.tenant_id='mezzo' and not exists (select 1 from sessions s where s.id = ar.session_id);
  if n > 0 then raise exception '% attendance rows point at a session that is gone', n; end if;

  /* The setup must survive, or he opens an app that cannot price
     anyone. Asserted as "still more than none" and by asking the fee
     chain a real question — NOT as fixed counts. The first cut of this
     file demanded exactly 2 batches and failed its own dry run three
     days later, because the tenant chat had meanwhile replaced the two
     time windows with eight day-pair batches (Mon/Thu, Tue/Fri, …). A
     check that encodes today's numbers rots the moment somebody
     improves the thing it is guarding. */
  if (select count(*) from sports   where tenant_id='mezzo' and active) = 0 then
    raise exception 'every instrument was deleted'; end if;
  if (select count(*) from batches  where tenant_id='mezzo' and active) = 0 then
    raise exception 'every class time was deleted'; end if;
  if (select count(*) from centres  where tenant_id='mezzo') = 0 then
    raise exception 'the venue was deleted'; end if;

  /* The one that actually matters: can he still be told what to charge?
     Two rules, two answers, from SQL. */
  if (resolve_fee('mezzo', null, (select id from centres where tenant_id='mezzo'),
                  'Piano', null, 1, null)->>'monthly')::numeric <> 2500 then
    raise exception 'the fee chain no longer prices piano at 2500'; end if;
  if (resolve_fee('mezzo', null, (select id from centres where tenant_id='mezzo'),
                  'Guitar', null, 1, null)->>'monthly')::numeric <> 1500 then
    raise exception 'the fee chain no longer prices guitar at 1500'; end if;

  raise notice 'setup intact: % instruments, % batches, piano 2500 / rest 1500',
    (select count(*) from sports  where tenant_id='mezzo' and active),
    (select count(*) from batches where tenant_id='mezzo' and active);
end $chk$;
