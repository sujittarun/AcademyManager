-- ============================================================
-- 2026-08-10p · GenAlpha's three admission RPCs, ported
-- scope: shared
--
-- These are the last thing standing between GenAlpha's app and the
-- platform. Its client calls three functions that exist only on its own
-- project:
--
--   submit_admission_form(...)        the public admission form
--   peek_next_admission_reg_no()      shows the parent their number
--   approve_admission(uuid, ...)      staff turn an application into a student
--
-- Ported, not copied. The originals write to GenAlpha's `admissions`,
-- `students` and `registration_counters`. Here the same work lands in
-- the platform's shared tables — public.applications, public.members,
-- public.enrollments — with only the genuinely GenAlpha-specific parts
-- kept aside.
--
-- WHY THEY LIVE IN THE genalpha SCHEMA
-- A cricket admission form asks for batting style, bowling styles,
-- jersey size and a parent's Aadhaar number. None of that is true of a
-- badminton venue or a tennis academy, so it is not platform vocabulary
-- and does not belong in public. The app reaches them with
-- .schema('genalpha').rpc(...) — one small change alongside the URL and
-- key change it needs anyway.
--
-- WHAT CHANGED ON PURPOSE
--
-- 1. genalpha.admissions becomes a TABLE. Stage I made it a view over
--    public.applications, which was fine for reading history and useless
--    for writing: applications has no column for nationality, aadhaar,
--    batting style, jersey size or the consent flags. A form that cannot
--    store what it asks for is not a port.
--
-- 2. Every admission now ALSO creates a public.applications row. That is
--    what makes GenAlpha a real tenant rather than a guest: the operator
--    console, tenant_health() and every shared function count its
--    applications like anybody else's.
--
-- 3. approve_admission creates a member AND an enrollment AND a
--    student_details row, in one transaction. The original only made a
--    student, because GenAlpha has no enrolment concept. On the platform
--    renewal_on lives on the enrolment and reminder_queue() reads it, so
--    an approved child with no enrolment would silently never be chased.
--
-- 4. The fee is written as a member-level fee_rule, not stored on the
--    child. GenAlpha prices per student; the platform's 7-level chain has
--    exactly that level. THE HOUSE RULE: the amount is what resolve_fee()
--    returns, not a number someone typed into a form.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The admission form's own storage.
-- ------------------------------------------------------------
drop view if exists genalpha.admissions;

create table if not exists genalpha.admissions (
  id                    uuid primary key default gen_random_uuid(),
  application_id        bigint unique references public.applications(id) on delete set null,
  reg_no                bigint,
  applicant_name        text not null,
  nationality           text,
  date_of_birth         date,
  age                   integer,
  gender                text,
  father_guardian_name  text,
  parent_contact_no     text,
  emergency_contact_no  text,
  city                  text,
  address               text,
  school_college        text,
  grade                 text,
  parent_aadhaar_no     text,
  time_slot             text,
  join_date             date,
  fees_paid             boolean default false,
  amount_paid           numeric default 0,
  fee_plan              text,
  coaching_fee          numeric default 0,
  admission_fee         numeric default 0,
  jersey_amount         numeric default 0,
  total_fee_amount      numeric default 0,
  jersey_size           text,
  jersey_pairs          integer default 0,
  payment_method        text,
  payment_upi_id        text,
  payment_reference     text,
  filled_by             text,
  comments              text,
  batsman_style         text,
  bowling_styles        text[],
  ready_to_start        boolean,
  consent_accepted      boolean not null,
  terms_accepted        boolean not null,
  review_status         text not null default 'pending'
                          check (review_status in ('pending','approved','rejected')),
  reviewed_at           timestamptz,
  reviewed_by           text,
  review_notes          text,
  approved_member_id    bigint references public.members(id) on delete set null,
  created_at            timestamptz not null default now()
);
create index if not exists genalpha_admissions_status_idx on genalpha.admissions(review_status, created_at desc);

alter table genalpha.admissions enable row level security;
-- Staff read and manage. Anonymous parents never read this table; they
-- only reach it through submit_admission_form, which is definer.
create policy genalpha_admissions_staff on genalpha.admissions
  for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.admissions from public, anon;
grant select, insert, update on genalpha.admissions to authenticated, service_role;

-- The registration counter. One row, hard-coded to this tenant — it is a
-- GenAlpha numbering scheme, not a platform one.
create table if not exists genalpha.registration_counters (
  counter_name text primary key,
  next_reg_no  bigint not null
);
insert into genalpha.registration_counters (counter_name, next_reg_no)
values ('admissions', 1001) on conflict (counter_name) do nothing;
alter table genalpha.registration_counters enable row level security;
create policy genalpha_counters_staff on genalpha.registration_counters
  for all to authenticated
  using (auth_role() in ('staff','operator'))
  with check (auth_role() in ('staff','operator'));
revoke all on genalpha.registration_counters from public, anon;
grant select, insert, update on genalpha.registration_counters to authenticated, service_role;

-- ------------------------------------------------------------
-- 2. peek_next_admission_reg_no — shows a parent the number they'll get.
--    Reads only. Anon-callable BY DESIGN: it is on the public form.
-- ------------------------------------------------------------
create or replace function genalpha.peek_next_admission_reg_no()
returns table (next_reg_no bigint)
language sql
stable
security definer
set search_path = genalpha, public
as $$
  select c.next_reg_no from genalpha.registration_counters c
   where c.counter_name = 'admissions'
$$;
comment on function genalpha.peek_next_admission_reg_no() is
  'Next admission number, for the public form. Read-only and anon-callable by design.';
revoke execute on function genalpha.peek_next_admission_reg_no() from public;
grant  execute on function genalpha.peek_next_admission_reg_no() to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- 3. submit_admission_form — the public form.
--    Anon-callable BY DESIGN. Signature kept identical to the original
--    so the app's call site does not change beyond the schema prefix.
-- ------------------------------------------------------------
create or replace function genalpha.submit_admission_form(
  p_applicant_name text, p_nationality text, p_date_of_birth date, p_age integer,
  p_gender text, p_father_guardian_name text, p_alternate_contact_no text,
  p_parent_contact_no text, p_city text, p_address text, p_school_college text,
  p_grade text, p_parent_aadhaar_no text, p_time_slot text, p_join_date date,
  p_fees_paid boolean, p_amount_paid numeric, p_jersey_size text, p_jersey_pairs integer,
  p_batsman_style text, p_bowling_styles text[], p_ready_to_start boolean,
  p_consent_accepted boolean, p_terms_accepted boolean,
  p_payment_method text default 'UPI', p_payment_upi_id text default '',
  p_payment_reference text default '', p_comments text default '',
  p_filled_by text default 'Parent / Guardian', p_fee_plan text default 'monthly',
  p_coaching_fee numeric default 0, p_admission_fee numeric default 0,
  p_jersey_amount numeric default 0, p_total_fee_amount numeric default 0)
returns table (id uuid, reg_no bigint)
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare v_reg bigint; v_app bigint; v_id uuid;
begin
  if not coalesce(p_consent_accepted,false) or not coalesce(p_terms_accepted,false) then
    raise exception 'Please accept the required consent and terms.';
  end if;
  -- This function is reachable without a session, so it validates rather
  -- than trusts. The original did neither.
  if coalesce(length(trim(p_applicant_name)),0) < 2 then
    raise exception 'Please enter the applicant''s name.';
  end if;
  if coalesce(length(regexp_replace(coalesce(p_parent_contact_no,''), '\D', '', 'g')),0) < 10 then
    raise exception 'Please enter a valid contact number.';
  end if;

  update genalpha.registration_counters
     set next_reg_no = next_reg_no + 1
   where counter_name = 'admissions'
  returning next_reg_no - 1 into v_reg;

  -- the platform-level row, so GenAlpha counts like every other tenant
  insert into public.applications (tenant_id, name, phone, parent_name, parent_phone,
                                   dob, gender, school, sport, status)
  values ('genalpha', p_applicant_name, p_parent_contact_no, p_father_guardian_name,
          p_parent_contact_no, p_date_of_birth, p_gender, p_school_college, 'cricket', 'pending')
  returning applications.id into v_app;

  insert into genalpha.admissions (
    application_id, reg_no, applicant_name, nationality, date_of_birth, age, gender,
    father_guardian_name, parent_contact_no, emergency_contact_no, city, address,
    school_college, grade, parent_aadhaar_no, time_slot, join_date, fees_paid,
    amount_paid, fee_plan, coaching_fee, admission_fee, jersey_amount, total_fee_amount,
    jersey_size, jersey_pairs, payment_method, payment_upi_id, payment_reference,
    filled_by, comments, batsman_style, bowling_styles, ready_to_start,
    consent_accepted, terms_accepted)
  values (
    v_app, v_reg, p_applicant_name, p_nationality, p_date_of_birth, p_age, p_gender,
    p_father_guardian_name, p_parent_contact_no, p_alternate_contact_no, p_city, p_address,
    p_school_college, p_grade, p_parent_aadhaar_no, p_time_slot, p_join_date,
    coalesce(p_fees_paid,false), coalesce(p_amount_paid,0), p_fee_plan,
    coalesce(p_coaching_fee,0), coalesce(p_admission_fee,0), coalesce(p_jersey_amount,0),
    coalesce(p_total_fee_amount,0), p_jersey_size, coalesce(p_jersey_pairs,0),
    p_payment_method, p_payment_upi_id, p_payment_reference, p_filled_by, p_comments,
    p_batsman_style, p_bowling_styles, p_ready_to_start, true, true)
  returning admissions.id into v_id;

  return query select v_id, v_reg;
end $$;

comment on function genalpha.submit_admission_form is
  'GenAlpha''s public admission form. Anon-callable BY DESIGN — a prospective parent has no account. Validates its inputs because it is reachable without a session.';
revoke execute on function genalpha.submit_admission_form(
  text,text,date,integer,text,text,text,text,text,text,text,text,text,text,date,
  boolean,numeric,text,integer,text,text[],boolean,boolean,boolean,
  text,text,text,text,text,text,numeric,numeric,numeric,numeric) from public;
grant execute on function genalpha.submit_admission_form(
  text,text,date,integer,text,text,text,text,text,text,text,text,text,text,date,
  boolean,numeric,text,integer,text,text[],boolean,boolean,boolean,
  text,text,text,text,text,text,numeric,numeric,numeric,numeric)
  to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- 4. approve_admission — staff turn an application into a real student.
--    STAFF ONLY. On GenAlpha's project this was anon-callable, which
--    meant a stranger could approve admissions. Guarded here.
-- ------------------------------------------------------------
create or replace function genalpha.approve_admission(
  p_admission_id uuid,
  p_reviewed_by  text default 'Manager',
  p_review_notes text default '')
returns table (member_id bigint, reg_no bigint)
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare a genalpha.admissions%rowtype; v_member bigint; v_centre bigint; v_batch bigint;
begin
  perform assert_staff_or_service('genalpha');

  select * into a from genalpha.admissions where id = p_admission_id for update;
  if not found then raise exception 'Admission not found.'; end if;

  -- idempotent: approving twice returns the same child rather than making a second
  if a.review_status = 'approved' and a.approved_member_id is not null then
    return query select a.approved_member_id, a.reg_no;
    return;
  end if;

  select id into v_centre from public.centres where tenant_id='genalpha' order by id limit 1;
  if v_centre is null then raise exception 'genalpha has no centre — cannot enrol'; end if;
  select id into v_batch from public.batches
   where tenant_id='genalpha'
     and (a.time_slot is null or name ilike '%'||a.time_slot||'%')
   order by (name ilike '%'||coalesce(a.time_slot,'~')||'%') desc, id limit 1;

  insert into public.members (tenant_id, name, phone, parent_name, parent_phone, alt_phone,
                              school, grade, address, dob, gender, joined, status, program)
  values ('genalpha', a.applicant_name, a.parent_contact_no, a.father_guardian_name,
          a.parent_contact_no, a.emergency_contact_no, a.school_college, a.grade,
          a.address, a.date_of_birth, a.gender,
          coalesce(a.join_date, current_date), 'active', 'Cricket')
  returning members.id into v_member;

  insert into genalpha.student_details (
    member_id, legacy_uuid, reg_no, time_slot, jersey_size, jersey_pairs,
    payment_method, payment_upi_id, payment_reference, fee_plan, coaching_fee,
    admission_fee, jersey_amount, total_fee_amount, admission_id, filled_by,
    fees_paid, amount_paid)
  values (v_member, gen_random_uuid(), a.reg_no, a.time_slot, a.jersey_size,
          a.jersey_pairs, a.payment_method, a.payment_upi_id, a.payment_reference,
          a.fee_plan, a.coaching_fee, a.admission_fee, a.jersey_amount,
          a.total_fee_amount, a.id, a.filled_by, a.fees_paid, a.amount_paid);

  -- The enrolment is not optional. renewal_on lives here and
  -- reminder_queue() reads it; a child approved without one is a child
  -- nobody ever chases for a fee.
  insert into public.enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                                  plan_months, joined_on, renewal_on, status)
  values ('genalpha', v_member, v_centre, v_batch, 'cricket',
          case when a.fee_plan = 'quarterly' then 3 else 1 end,
          coalesce(a.join_date, current_date),
          coalesce(a.join_date, current_date)
            + (case when a.fee_plan = 'quarterly' then 3 else 1 end || ' months')::interval,
          'active');

  -- The fee becomes a RULE, not a number on the child. resolve_fee() is
  -- the only thing allowed to answer "what does this family owe".
  if coalesce(a.coaching_fee,0) > 0 then
    insert into public.fee_rules (tenant_id, label, member_id, monthly_amount,
                                  admission_fee, active, effective_from)
    values ('genalpha', 'Student fee · ' || a.applicant_name, v_member,
            a.coaching_fee, coalesce(a.admission_fee,0), true,
            coalesce(a.join_date, current_date));
  end if;

  update genalpha.admissions
     set review_status='approved', reviewed_at=now(),
         reviewed_by=coalesce(nullif(p_reviewed_by,''),'Manager'),
         review_notes=p_review_notes, approved_member_id=v_member
   where id = a.id;

  update public.applications
     set status='approved', reviewed_at=now(),
         reviewed_by=coalesce(nullif(p_reviewed_by,''),'Manager'),
         member_id=v_member
   where id = a.application_id;

  return query select v_member, a.reg_no;
end $$;

comment on function genalpha.approve_admission(uuid, text, text) is
  'Turns an admission into a member + enrolment + fee rule. STAFF ONLY — on the old project this was anon-callable, so a stranger could approve admissions.';
revoke execute on function genalpha.approve_admission(uuid, text, text) from public, anon;
grant  execute on function genalpha.approve_admission(uuid, text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Checks — exercise the functions, do not just look at them
-- ------------------------------------------------------------
do $$
declare v_id uuid; v_reg bigint; v_next bigint; v_member bigint; n int;
begin
  -- a centre must exist or approve_admission cannot enrol
  if not exists (select 1 from centres where tenant_id='genalpha') then
    insert into centres (tenant_id, code, name, short_name, active, sort)
    values ('genalpha','GA','GenAlpha Cricket Academy','GenAlpha',true,1);
  end if;

  select next_reg_no into v_next from genalpha.registration_counters where counter_name='admissions';

  -- submit
  select s.id, s.reg_no into v_id, v_reg
    from genalpha.submit_admission_form(
      'Selftest Child'::text, 'Indian'::text,
      (current_date - interval '10 years')::date, 10, 'M'::text,
      'Selftest Parent'::text, '9000000001'::text, '9000000002'::text,
      'Bengaluru'::text, '1 Test Road'::text, 'Test School'::text, '5'::text,
      ''::text, '6AM'::text, current_date, false, 0::numeric, 'M'::text, 1,
      'right-hand'::text, array['medium']::text[], true, true, true) s;
  if v_id is null then raise exception 'submit_admission_form returned no id'; end if;
  if v_reg <> v_next then raise exception 'reg_no % did not match the peeked %', v_reg, v_next; end if;

  -- the platform row must exist too, or genalpha is a guest not a tenant
  if not exists (select 1 from applications where tenant_id='genalpha'
                   and id = (select application_id from genalpha.admissions where id=v_id)) then
    raise exception 'no public.applications row was created';
  end if;

  -- approve
  select a.member_id into v_member from genalpha.approve_admission(v_id,'Selftest','') a;
  if v_member is null then raise exception 'approve_admission returned no member'; end if;

  -- and the enrolment must exist, or nobody would ever chase this family
  if not exists (select 1 from enrollments where tenant_id='genalpha' and member_id=v_member) then
    raise exception 'approved child has no enrolment';
  end if;
  if not exists (select 1 from genalpha.student_details where member_id=v_member) then
    raise exception 'approved child has no side row';
  end if;

  -- idempotent
  select a.member_id into n from genalpha.approve_admission(v_id,'Selftest','') a;
  if n <> v_member then raise exception 'approving twice created a second child'; end if;

  -- clean the self-test up entirely
  delete from fee_rules   where tenant_id='genalpha' and member_id=v_member;
  delete from enrollments where tenant_id='genalpha' and member_id=v_member;
  delete from genalpha.student_details where member_id=v_member;
  delete from members     where id=v_member;
  delete from applications where id=(select application_id from genalpha.admissions where id=v_id);
  delete from genalpha.admissions where id=v_id;
  update genalpha.registration_counters set next_reg_no = v_next where counter_name='admissions';

  select count(*) into n from members where tenant_id='genalpha';
  if n <> 0 then raise exception 'self-test left % genalpha members behind', n; end if;

  raise notice 'all three RPCs exercised end to end and cleaned up';
end $$;
