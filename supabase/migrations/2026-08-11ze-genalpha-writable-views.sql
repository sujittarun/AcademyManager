-- ============================================================
-- 2026-08-11ze · Every write the app makes is rejected
-- scope: shared
--
-- genalpha.students, .student_payments and .academy_expenses are
-- multi-relation views with `grant select` and no INSTEAD OF trigger
-- anywhere. A join view is not auto-updatable in Postgres regardless of
-- privilege, so the grant is not the problem and widening it would not
-- help.
--
-- What is broken, all of it daily: recording a renewal or joining fee,
-- confirming a WhatsApp payment proof, a jersey adjustment, deleting a
-- payment, adding or editing a player, discontinuing and rejoining,
-- deleting a player, adding or deleting an expense.
--
-- Reads all work, so every screen renders fully populated. That is why
-- this survived a cutover.
--
-- SHAPE OF THE FIX. The alternative was RPCs plus a synchronised app
-- deploy. These views exist so GenAlpha's app did not have to change, and
-- a tenant app is handed to a client — the fix that needs no client
-- release is the better one. So the views learn to accept exactly what
-- the app already sends, and INSTEAD OF triggers fan each write out to
-- the right shared and tenant tables. Zero JS changes.
--
-- THE TRAP THIS AVOIDS. The obvious version of this migration grants
-- insert and writes public.payments directly. That would show families
-- paid while reminder_queue() kept chasing them, because
-- enrollments.renewal_on is rolled forward by record_fee_payment() and
-- by nothing else. The gap would widen by one cycle per payment and be
-- visible only from the parent's side. So the payment trigger calls
-- record_fee_payment(), and the delete calls void_payment(). The house
-- rule is not decoration here; it is the difference between a working
-- reminder ladder and a silent one.
-- ============================================================

-- ------------------------------------------------------------
-- 1. student_payments: accept what the app sends
-- ------------------------------------------------------------
-- plan_type was never migrated into public.payments and cannot be
-- recovered from `kind`. It is derived here from kind + months, which
-- reproduces it for every case the app can produce, and it makes
-- getPaymentPlanLabel (script.js:1319) and fee-plan-rules.js:19 work
-- again — both silently degraded to "Monthly" for every special and
-- multi-month payment.
--
-- The six joining-fee columns are per-student facts that live on
-- student_details. They are read from there and, on write, routed back
-- there. The app sends them alongside a payment because that is how
-- GenAlpha's single table was shaped; the view keeps that shape.
drop view if exists genalpha.student_payments cascade;
create view genalpha.student_payments with (security_invoker = true) as
  select p.id::text                                as id,
         d.legacy_uuid                             as student_id,
         case p.kind when 'renewal'   then 'renewal'
                     when 'admission' then 'joining'
                     when 'custom'    then 'jersey'
                     else p.kind end               as payment_type,
         case
           when p.kind = 'custom'                     then 'jersey_pair'
           when d.fee_plan = 'special'                then 'special'
           when coalesce(p.months, 1) = 3             then 'quarterly'
           when coalesce(p.months, 1) = 6             then 'halfyearly'
           when coalesce(p.months, 1) = 1             then 'monthly'
           else 'custom' end                       as plan_type,
         p.months                                  as months_covered,
         p.period_from                             as cycle_start_date,
         p.amount,
         p.on_date                                 as paid_on,
         p.note                                    as comment,
         p.collected_by                            as recorded_by,
         p.created_at,
         p.proof_path,
         p.ref                                     as payment_reference,
         p.status                                  as verification_status,
         p.mode                                    as payment_method,
         p.kind,
         -- per-student, not per-payment; the app sends them on a joining
         -- fee and reads them back off the row
         d.coaching_fee,
         d.admission_fee,
         d.jersey_amount,
         d.total_fee_amount,
         d.jersey_size,
         d.jersey_pairs
    from payments p
    join genalpha.student_details d on d.member_id = p.member_id
   where p.tenant_id = 'genalpha';

revoke all on genalpha.student_payments from public, anon;
grant select, insert, update, delete on genalpha.student_payments to authenticated, service_role;

create or replace function genalpha.student_payments_write()
returns trigger language plpgsql security definer set search_path = genalpha, public as $fn$
declare
  v_member bigint; v_enroll bigint; v_months int; v_kind text; v_result jsonb; v_id bigint;
begin
  if tg_op = 'DELETE' then
    -- Reversal is not a delete. void_payment() writes the reversal, the
    -- timeline entry and pulls renewal_on back; a raw delete would leave
    -- the family's renewal date sitting on coverage they no longer have.
    perform void_payment('genalpha', old.id::bigint, 'Deleted from the GenAlpha app');
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;
  if v_member is null then
    raise exception 'No GenAlpha player with id %', new.student_id;
  end if;

  if tg_op = 'UPDATE' then
    -- Only the annotations are editable. Amounts and dates go through
    -- void-and-rerecord, so there is no path that changes money without
    -- the platform recomputing coverage.
    update payments
       set note        = coalesce(new.comment, note),
           proof_path  = coalesce(new.proof_path, proof_path),
           ref         = coalesce(new.payment_reference, ref),
           status      = coalesce(new.verification_status, status),
           collected_by = coalesce(new.recorded_by, collected_by)
     where id = old.id::bigint and tenant_id = 'genalpha';
    return new;
  end if;

  select e.id into v_enroll from enrollments e
   where e.tenant_id='genalpha' and e.member_id = v_member order by e.id limit 1;
  if v_enroll is null then
    raise exception 'That player has no enrollment to pay against.';
  end if;

  v_kind := case coalesce(new.payment_type, 'renewal')
              when 'joining' then 'admission'
              when 'jersey'  then 'custom'
              else 'renewal' end;

  -- record_fee_payment only accepts 1/3/6/12. An off-ladder special (a
  -- 2- or 4-month block) passes null, which stores months_covered NULL —
  -- and the app then guesses the month count back from the amount, which
  -- credits 6 months for a 20,000 two-month renewal. So the ladder months
  -- go through as themselves and anything else is recorded as a custom
  -- payment carrying its real month count, set immediately below.
  v_months := case when coalesce(new.months_covered,1) in (1,3,6,12)
                   then new.months_covered else null end;

  v_result := record_fee_payment(
    'genalpha', v_enroll, new.amount, v_months, coalesce(new.payment_method,'UPI'),
    v_kind, coalesce(new.paid_on, ist_today()), nullif(new.payment_reference,''),
    'paid', coalesce(new.recorded_by,'GenAlpha app'), new.comment);
  v_id := (v_result->>'payment_id')::bigint;

  update payments
     set proof_path = coalesce(nullif(new.proof_path,''), proof_path),
         months     = coalesce(v_months, greatest(coalesce(new.months_covered,1),1))
   where id = v_id;

  -- Joining-fee detail belongs to the student, not the payment.
  if new.payment_type = 'joining' then
    update genalpha.student_details
       set fees_paid        = true,
           payment_status   = 'paid',
           amount_paid      = coalesce(new.amount, amount_paid),
           coaching_fee     = coalesce(new.coaching_fee, coaching_fee),
           admission_fee    = coalesce(new.admission_fee, admission_fee),
           jersey_amount    = coalesce(new.jersey_amount, jersey_amount),
           total_fee_amount = coalesce(new.total_fee_amount, total_fee_amount),
           jersey_size      = coalesce(nullif(new.jersey_size,''), jersey_size),
           jersey_pairs     = coalesce(new.jersey_pairs, jersey_pairs)
     where member_id = v_member;
  elsif new.payment_type = 'renewal' then
    update genalpha.student_details
       -- renewals is JSONB, not date[]. 2026-08-11t's
       -- finalize_renewal_intake got this wrong and dry-ran clean,
       -- because plpgsql does not type-check a function body at creation
       -- time — it would have failed on the first WhatsApp renewal. Fixed
       -- there too, at the end of this file.
       set renewals = (
         select jsonb_agg(distinct x order by x)
           from jsonb_array_elements_text(
                  coalesce(renewals, '[]'::jsonb)
                  || jsonb_build_array(coalesce(new.cycle_start_date, ist_today())::text)) x)
     where member_id = v_member;
  end if;

  new.id := v_id::text;
  return new;
end $fn$;

create trigger student_payments_iud instead of insert or update or delete
  on genalpha.student_payments for each row execute function genalpha.student_payments_write();

-- ------------------------------------------------------------
-- 2. students
-- ------------------------------------------------------------
create or replace function genalpha.students_write()
returns trigger language plpgsql security definer set search_path = genalpha, public as $fn$
declare v_member bigint; v_uuid uuid;
begin
  if tg_op = 'DELETE' then
    select member_id into v_member from genalpha.student_details where legacy_uuid = old.id;
    -- tenant_id in the WHERE: ids are global (PLATFORM.md rule 2).
    delete from members where id = v_member and tenant_id = 'genalpha';
    return old;
  end if;

  if tg_op = 'INSERT' then
    v_uuid := coalesce(new.id, gen_random_uuid());
    insert into members (tenant_id, name, dob, joined, status, program, notes,
                         parent_name, parent_phone, phone, alt_phone, school, grade,
                         address, reg_no, added_by, updated_by, whatsapp_status,
                         reminders_paused, rejoined_at)
    values ('genalpha', new.name, null, coalesce(new.join_date, current_date),
            case when coalesce(new.discontinued,false) then 'discontinued' else 'active' end,
            'Cricket', new.comments, new.father_guardian_name, new.parent_contact_no,
            new.parent_contact_no, new.alternate_contact_no, new.school_college, new.grade,
            new.address, new.reg_no, new.added_by, new.updated_by,
            coalesce(new.whatsapp_contact_status,'unknown'),
            coalesce(new.whatsapp_reminders_paused,false), new.rejoined_at)
    returning id into v_member;

    insert into genalpha.student_details (
      member_id, legacy_uuid, reg_no, age, time_slot, jersey_size, jersey_pairs,
      payment_method, payment_upi_id, payment_reference, fee_plan, coaching_fee,
      admission_fee, jersey_amount, total_fee_amount, fee_pause_days, rejoined_at,
      added_by, updated_by, filled_by, payment_status, fees_paid, amount_paid, renewals)
    values (v_member, v_uuid, new.reg_no, new.age, new.time_slot, new.jersey_size,
            coalesce(new.jersey_pairs,0), new.payment_method, new.payment_upi_id,
            new.payment_reference, coalesce(new.fee_plan,'monthly'), new.coaching_fee,
            new.admission_fee, new.jersey_amount, new.total_fee_amount,
            coalesce(new.fee_pause_days,0), new.rejoined_at, new.added_by, new.updated_by,
            new.filled_by, coalesce(new.payment_status,'pending'),
            coalesce(new.fees_paid,false), new.amount_paid,
            coalesce(new.renewals, '[]'::jsonb));

    new.id := v_uuid;
    return new;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = old.id;
  if v_member is null then raise exception 'No GenAlpha player with id %', old.id; end if;

  update members
     set name             = coalesce(new.name, name),
         joined           = coalesce(new.join_date, joined),
         status           = case when new.discontinued is null then status
                                 when new.discontinued then 'discontinued' else 'active' end,
         discontinued_on  = case when coalesce(new.discontinued,false)
                                 then coalesce(new.discontinued_at, discontinued_on, current_date)
                                 else null end,
         rejoined_at      = coalesce(new.rejoined_at, rejoined_at),
         notes            = coalesce(new.comments, notes),
         parent_name      = coalesce(new.father_guardian_name, parent_name),
         parent_phone     = coalesce(new.parent_contact_no, parent_phone),
         phone            = coalesce(new.parent_contact_no, phone),
         alt_phone        = coalesce(new.alternate_contact_no, alt_phone),
         school           = coalesce(new.school_college, school),
         grade            = coalesce(new.grade, grade),
         address          = coalesce(new.address, address),
         reg_no           = coalesce(new.reg_no, reg_no),
         updated_by       = coalesce(new.updated_by, updated_by),
         whatsapp_status  = coalesce(new.whatsapp_contact_status, whatsapp_status),
         reminders_paused = coalesce(new.whatsapp_reminders_paused, reminders_paused),
         reminders_paused_at = coalesce(new.whatsapp_reminders_paused_at, reminders_paused_at),
         reminders_paused_by = coalesce(new.whatsapp_reminders_paused_by, reminders_paused_by),
         updated_at       = now()
   where id = v_member and tenant_id = 'genalpha';

  update genalpha.student_details
     set age              = coalesce(new.age, age),
         time_slot        = coalesce(new.time_slot, time_slot),
         jersey_size      = coalesce(new.jersey_size, jersey_size),
         jersey_pairs     = coalesce(new.jersey_pairs, jersey_pairs),
         payment_method   = coalesce(new.payment_method, payment_method),
         payment_upi_id   = coalesce(new.payment_upi_id, payment_upi_id),
         payment_reference = coalesce(new.payment_reference, payment_reference),
         fee_plan         = coalesce(new.fee_plan, fee_plan),
         coaching_fee     = coalesce(new.coaching_fee, coaching_fee),
         admission_fee    = coalesce(new.admission_fee, admission_fee),
         jersey_amount    = coalesce(new.jersey_amount, jersey_amount),
         total_fee_amount = coalesce(new.total_fee_amount, total_fee_amount),
         fee_pause_days   = coalesce(new.fee_pause_days, fee_pause_days),
         rejoined_at      = coalesce(new.rejoined_at, rejoined_at),
         payment_status   = coalesce(new.payment_status, payment_status),
         fees_paid        = coalesce(new.fees_paid, fees_paid),
         amount_paid      = coalesce(new.amount_paid, amount_paid),
         renewals         = coalesce(new.renewals, renewals),
         updated_by       = coalesce(new.updated_by, updated_by)
   where member_id = v_member;

  return new;
end $fn$;

create trigger students_iud instead of insert or update or delete
  on genalpha.students for each row execute function genalpha.students_write();

grant select, insert, update, delete on genalpha.students to authenticated, service_role;

-- ------------------------------------------------------------
-- 3. academy_expenses
-- ------------------------------------------------------------
-- The app sends created_by, which the view does not have and
-- public.expenses has no column for. It is folded into `detail` rather
-- than dropped: who recorded a payout is the kind of thing someone asks
-- about six months later.
drop view if exists genalpha.academy_expenses cascade;
create view genalpha.academy_expenses with (security_invoker = true) as
  select e.id::text                as id,
         e.category                as expense_type,
         e.amount,
         e.detail                  as comment,
         e.payee                   as paid_by,
         e.on_date                 as expense_date,
         e.created_at,
         e.ref                     as created_by
    from expenses e
   where e.tenant_id = 'genalpha';

revoke all on genalpha.academy_expenses from public, anon;
grant select, insert, update, delete on genalpha.academy_expenses to authenticated, service_role;

create or replace function genalpha.academy_expenses_write()
returns trigger language plpgsql security definer set search_path = genalpha, public as $fn$
declare v_id bigint;
begin
  if tg_op = 'DELETE' then
    -- public.expenses has SELECT and INSERT policies and no DELETE one
    -- (schema.sql:1459). Inside a definer function RLS does not apply, so
    -- this works — but tenant_id stays in the WHERE, because ids are
    -- global and `delete from expenses where id = $1` reaches every
    -- academy.
    delete from expenses where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  if tg_op = 'INSERT' then
    insert into expenses (tenant_id, category, payee, detail, amount, on_date, ref, mode)
    values ('genalpha', new.expense_type, new.paid_by, new.comment,
            new.amount, coalesce(new.expense_date, ist_today()), new.created_by, 'cash')
    returning id into v_id;
    new.id := v_id::text;
    return new;
  end if;

  update expenses
     set category = coalesce(new.expense_type, category),
         payee    = coalesce(new.paid_by, payee),
         detail   = coalesce(new.comment, detail),
         amount   = coalesce(new.amount, amount),
         on_date  = coalesce(new.expense_date, on_date)
   where id = old.id::bigint and tenant_id = 'genalpha';
  return new;
end $fn$;

create trigger academy_expenses_iud instead of insert or update or delete
  on genalpha.academy_expenses for each row execute function genalpha.academy_expenses_write();

revoke execute on function genalpha.student_payments_write()  from public, anon;
revoke execute on function genalpha.students_write()          from public, anon;
revoke execute on function genalpha.academy_expenses_write()  from public, anon;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v_uuid uuid; v_member bigint; v_pay text; v_exp text;
  m0 int; p0 int; e0 int; n int;
  v_renewal_before date; v_renewal_after date;
begin
  select count(*) into m0 from members   where tenant_id='genalpha';
  select count(*) into p0 from payments  where tenant_id='genalpha';
  select count(*) into e0 from expenses  where tenant_id='genalpha';

  -- ---- a player, through the view, exactly as the app inserts one ----
  insert into genalpha.students
    (name, age, join_date, time_slot, fee_plan, coaching_fee, admission_fee,
     jersey_amount, total_fee_amount, jersey_size, jersey_pairs, renewals,
     added_by, updated_by, discontinued, father_guardian_name, parent_contact_no,
     whatsapp_contact_status, alternate_contact_no, fees_paid, amount_paid)
  values ('ZZ Probe Player', 9, current_date, '6AM', 'monthly', 3500, 500,
          0, 4000, 'M', 0, '[]'::jsonb, 'probe', 'probe', false,
          'ZZ Probe Parent', '9000000001', 'unknown', '', false, 0)
  returning id into v_uuid;

  if v_uuid is null then raise exception 'inserting a player through the view returned no id'; end if;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_uuid;
  if v_member is null then raise exception 'the student_details half of the insert is missing'; end if;
  if not exists (select 1 from members where id=v_member and tenant_id='genalpha' and name='ZZ Probe Player') then
    raise exception 'the members half of the insert is missing';
  end if;
  -- and it reads back as one row through the view
  if not exists (select 1 from genalpha.students
                  where id=v_uuid and name='ZZ Probe Player' and time_slot='6AM' and coaching_fee=3500) then
    raise exception 'the two halves do not read back as one player';
  end if;

  -- ---- edit, the update path ----
  update genalpha.students set name='ZZ Probe Renamed', time_slot='4PM', grade='5' where id=v_uuid;
  if not exists (select 1 from genalpha.students
                  where id=v_uuid and name='ZZ Probe Renamed' and time_slot='4PM' and grade='5') then
    raise exception 'the update did not reach both halves';
  end if;

  -- ---- discontinue and rejoin ----
  update genalpha.students set discontinued=true, discontinued_at=current_date where id=v_uuid;
  if not exists (select 1 from genalpha.students where id=v_uuid and discontinued) then
    raise exception 'discontinue did not take';
  end if;
  update genalpha.students set discontinued=false where id=v_uuid;
  if exists (select 1 from genalpha.students where id=v_uuid and discontinued) then
    raise exception 'rejoin did not take';
  end if;

  -- an enrolment for the payment to land on
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, joined_on, renewal_on, status)
  select 'genalpha', v_member, e.centre_id, e.batch_id, 'cricket',
         1, current_date, current_date, 'active'
    from enrollments e where e.tenant_id='genalpha' order by e.id limit 1;
  select renewal_on into v_renewal_before from enrollments where member_id=v_member;

  -- ---- a renewal payment, the flow the academy uses daily ----
  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, comment, recorded_by)
  values (v_uuid, 'renewal', 'monthly', current_date, 1, 3500, current_date,
          'probe renewal', 'probe')
  returning id into v_pay;

  if v_pay is null then raise exception 'the payment insert returned no id'; end if;
  if not exists (select 1 from payments where id=v_pay::bigint and tenant_id='genalpha' and kind='renewal') then
    raise exception 'the payment did not reach public.payments';
  end if;

  -- THE POINT. record_fee_payment must have rolled the renewal forward.
  -- A trigger that inserted into payments directly would pass every check
  -- above and leave this one date behind, and reminder_queue() would keep
  -- chasing a family that had paid.
  select renewal_on into v_renewal_after from enrollments where member_id=v_member;
  if v_renewal_after <= v_renewal_before then
    raise exception 'renewal_on did not move (% -> %) — the payment bypassed record_fee_payment',
      v_renewal_before, v_renewal_after;
  end if;

  -- the timeline entry too
  if not exists (select 1 from member_timeline
                  where member_id=v_member and tenant_id='genalpha' and kind='payment') then
    raise exception 'no timeline entry was written for the payment';
  end if;

  -- plan_type must come back, since the app reads it for every label
  if (select plan_type from genalpha.student_payments where id=v_pay) <> 'monthly' then
    raise exception 'plan_type did not derive correctly';
  end if;

  -- ---- deleting a payment must VOID, not vanish ----
  delete from genalpha.student_payments where id=v_pay;
  if not exists (select 1 from payments where id=v_pay::bigint and status <> 'paid') then
    raise exception 'deleting a payment did not void it — money vanished instead of reversing';
  end if;

  -- ---- an expense, including the created_by the app sends ----
  insert into genalpha.academy_expenses (expense_type, amount, comment, paid_by, created_by, expense_date)
  values ('Equipment', 1200, 'probe expense', 'ZZ Probe Vendor', 'probe@example.invalid', current_date)
  returning id into v_exp;
  if v_exp is null then raise exception 'the expense insert returned no id'; end if;
  if not exists (select 1 from genalpha.academy_expenses
                  where id=v_exp and created_by='probe@example.invalid' and amount=1200) then
    raise exception 'created_by was dropped instead of preserved';
  end if;
  delete from genalpha.academy_expenses where id=v_exp;
  if exists (select 1 from expenses where id=v_exp::bigint) then
    raise exception 'the expense delete did not take';
  end if;

  -- ---- clean up entirely ----
  delete from payments        where member_id=v_member;
  delete from member_timeline where member_id=v_member;
  delete from enrollments     where member_id=v_member;
  delete from genalpha.students where id=v_uuid;

  if (select count(*) from members  where tenant_id='genalpha') <> m0 then
    raise exception 'the probe left a member behind'; end if;
  if (select count(*) from payments where tenant_id='genalpha') <> p0 then
    raise exception 'the probe left a payment behind'; end if;
  if (select count(*) from expenses where tenant_id='genalpha') <> e0 then
    raise exception 'the probe left an expense behind'; end if;

  -- ---- and nothing became reachable that should not be ----
  select count(*) into n from information_schema.role_table_grants
   where table_schema='genalpha' and grantee='anon';
  if n <> 0 then raise exception 'anon gained % grant(s) in the genalpha schema', n; end if;

  raise notice 'players, payments and expenses are writable again; renewal_on moved % -> %',
    v_renewal_before, v_renewal_after;
end $$;

-- ------------------------------------------------------------
-- 4. The same bug, in a function written earlier today
-- ------------------------------------------------------------
-- 2026-08-11t's finalize_renewal_intake appends to student_details.renewals
-- as if it were date[]. It is jsonb. plpgsql does not type-check a
-- function body at creation, so that migration dry-ran clean, applied
-- clean, and would have thrown 42804 the first time a parent's renewal
-- was confirmed over WhatsApp — after record_fee_payment had already
-- taken the money, inside the same transaction, so the whole confirmation
-- would have rolled back and the staff member would have seen a failure
-- for a payment the parent had made.
--
-- Found by the probe below trying the same expression and failing on the
-- type. Only replacing the one statement; the rest of the function is
-- correct and re-typing it by hand is how a difference gets lost.
do $$
declare src text; fixed text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'genalpha' and p.proname = 'finalize_renewal_intake';
  if src is null then raise exception 'finalize_renewal_intake is missing'; end if;

  fixed := replace(src,
    $old$         renewals         = case when v_is_joining then renewals else (
                              select array_agg(distinct x order by x)
                                from unnest(coalesce(renewals, '{}'::date[]) || array[v_cycle_start]) x
                            ) end,$old$,
    $new$         renewals         = case when v_is_joining then renewals else (
                              select jsonb_agg(distinct x order by x)
                                from jsonb_array_elements_text(
                                       coalesce(renewals, '[]'::jsonb)
                                       || jsonb_build_array(v_cycle_start::text)) x
                            ) end,$new$);

  if fixed = src then
    raise exception 'could not find the renewals expression in finalize_renewal_intake — refusing to guess';
  end if;
  execute fixed;
  raise notice 'finalize_renewal_intake: renewals now appended as jsonb';
end $$;

do $$
begin
  if (select pg_get_functiondef(p.oid) from pg_proc p
        join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='genalpha' and p.proname='finalize_renewal_intake') ~ 'date\[\]' then
    raise exception 'finalize_renewal_intake still treats renewals as an array';
  end if;
end $$;
