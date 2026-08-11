-- ============================================================
-- 2026-08-11zs · The remaining ten triggers
-- scope: shared
--
-- 2026-08-11zr restored the two that write the player timeline from
-- WhatsApp events. These are the other ten, and between them they are
-- most of what made GenAlpha's student record behave:
--
--   students          set_updated_at
--                     ensure_student_pause_billing_fields
--                     set_student_reminder_pause_audit
--                     sync_whatsapp_contact_followup
--                     log_student_life_timeline        (insert + update)
--   student_payments  log_student_payment_life_timeline
--                     preserve_admission_claim_payment_values
--                     reconcile_admission_claim_from_payment
--   admissions        guard_intake_admission_type
--                     link_admission_claim_to_approved_student
--
-- THREE DIFFERENT PLACES, decided by what the object actually is here.
--
--   genalpha.admissions is a REAL table, so its two triggers are created
--   on it directly, as triggers, exactly as they were.
--
--   students and student_payments are VIEWS. A view takes no BEFORE or
--   AFTER trigger, and the fields these read live across public.members,
--   genalpha.student_details and public.payments. So each becomes a
--   function over the view's rowtype, called from the INSTEAD OF trigger
--   that already mediates those writes — which receives `new` and `old`
--   in exactly the shape the original trigger expected.
--
--   The ones that RESHAPE the row (pause billing, reminder-pause audit,
--   claim value preservation) return the modified row and the caller
--   assigns it, because a called function cannot mutate the caller's
--   `new`. The ones that only have side effects return void.
--
-- set_updated_at needs no port: genalpha.students_write() already sets
-- members.updated_at = now() on every update. Noted rather than silently
-- skipped.
--
-- WHAT CHANGED IN THE PORT, and it is one thing:
-- link_admission_claim_to_approved_student reads approved_student_id, a
-- uuid. The merge renamed that column to approved_member_id and made it a
-- bigint referencing members.id. The claim's student_id is still
-- GenAlpha's uuid, so the port resolves the member back to its
-- legacy_uuid rather than writing a bigint into a uuid column.
-- ============================================================

-- ------------------------------------------------------------
-- 1. admissions: a real table, so real triggers
-- ------------------------------------------------------------
create or replace function genalpha.guard_intake_admission_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.intake_session_id is not null and exists(
    select 1 from genalpha.admission_intake_sessions s
    where s.id = new.intake_session_id and s.intake_type <> 'admission'
  ) then
    raise exception 'Only admission intake sessions may create admissions.';
  end if;
  return new;
end;
$function$;

-- approved_student_id (uuid) became approved_member_id (bigint) in the
-- merge. The claim still keys on GenAlpha's uuid, so resolve back to it.
create or replace function genalpha.link_admission_claim_to_approved_student()
returns trigger
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare v_legacy uuid;
begin
  if new.approved_member_id is not null
     and new.approved_member_id is distinct from old.approved_member_id then
    select legacy_uuid into v_legacy
      from genalpha.student_details where member_id = new.approved_member_id;
    if v_legacy is not null then
      update genalpha.admission_payment_claims
         set student_id = v_legacy
       where admission_id = new.id;
    end if;
  end if;
  return new;
end $fn$;

drop trigger if exists admissions_guard_intake_type on genalpha.admissions;
create trigger admissions_guard_intake_type
  before insert or update on genalpha.admissions
  for each row execute function genalpha.guard_intake_admission_type();

drop trigger if exists admissions_link_intake_payment_claim on genalpha.admissions;
create trigger admissions_link_intake_payment_claim
  after update on genalpha.admissions
  for each row execute function genalpha.link_admission_claim_to_approved_student();

revoke execute on function genalpha.guard_intake_admission_type() from public, anon;
revoke execute on function genalpha.link_admission_claim_to_approved_student() from public, anon;

-- ------------------------------------------------------------
-- 2. The view-backed ones, as functions over the view's rowtype
-- ------------------------------------------------------------
create or replace function genalpha.ensure_student_pause_billing_fields(
  new_row genalpha.students, old_row genalpha.students, p_op text default 'UPDATE'
)
returns genalpha.students
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare
  today_ist date := (timezone('Asia/Kolkata', now()))::date;
  pause_start date;
  pause_days integer;
begin
  if new_row.fee_pause_days is null then
    new_row.fee_pause_days := 0;
  end if;

  if new_row.discontinued is true
     and (p_op = 'INSERT' or old_row.discontinued is distinct from true) then
    new_row.discontinued_at := coalesce(new_row.discontinued_at, today_ist);
  end if;

  if p_op = 'UPDATE'
     and old_row.discontinued is true
     and new_row.discontinued is false then
    new_row.rejoined_at := coalesce(new_row.rejoined_at, today_ist);
    pause_start := coalesce(old_row.discontinued_at, new_row.discontinued_at, old_row.updated_at::date, old_row.created_at::date, today_ist);
    pause_days := greatest(new_row.rejoined_at - pause_start, 0);

    if new_row.fee_pause_days is not distinct from old_row.fee_pause_days then
      new_row.fee_pause_days := coalesce(old_row.fee_pause_days, 0) + pause_days;
    end if;
  end if;

  return new_row;
end;
$fn$;

revoke execute on function genalpha.ensure_student_pause_billing_fields(genalpha.students, genalpha.students, text) from public, anon;

create or replace function genalpha.set_student_reminder_pause_audit(
  new_row genalpha.students, old_row genalpha.students, p_op text default 'UPDATE'
)
returns genalpha.students
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
begin
  if new_row.whatsapp_reminders_paused is distinct from old_row.whatsapp_reminders_paused then
    if new_row.whatsapp_reminders_paused then
      new_row.whatsapp_reminders_paused_at := now();
      new_row.whatsapp_reminders_paused_by :=
        coalesce(nullif(new_row.updated_by, ''), nullif(new_row.added_by, ''), 'Manager');
    else
      new_row.whatsapp_reminders_paused_at := null;
      new_row.whatsapp_reminders_paused_by := '';
    end if;
  end if;
  return new_row;
end;
$fn$;

revoke execute on function genalpha.set_student_reminder_pause_audit(genalpha.students, genalpha.students, text) from public, anon;

create or replace function genalpha.sync_whatsapp_contact_followup(
  new_row genalpha.students, old_row genalpha.students, p_op text default 'UPDATE'
)
returns void
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare
  v_actor text;
begin
  if new_row.whatsapp_contact_status is not distinct from old_row.whatsapp_contact_status then
    return;
  end if;

  v_actor := coalesce(nullif(new_row.updated_by, ''), 'System');

  if new_row.whatsapp_contact_status in ('wrong_number', 'opted_out') then
    update genalpha.reminder_events
    set
      status = 'manual_followup',
      manual_followup_required = true,
      manual_followup_reason = case
        when new_row.whatsapp_contact_status = 'wrong_number' then 'wrong_phone_number'
        else 'whatsapp_opted_out'
      end,
      next_retry_at = null,
      retry_reason = case
        when new_row.whatsapp_contact_status = 'wrong_number'
          then 'Saved WhatsApp number is marked wrong. Automatic reminders and retries are paused.'
        else 'Parent has opted out of WhatsApp reminders. Automatic reminders and retries are paused.'
      end
    where student_id = new_row.id
      and delivered_at is null
      and read_at is null
      and status in (
        'queued', 'retry_scheduled', 'failed', 'send_failed',
        'delivery_failed', 'undelivered', 'manual_followup'
      );

    insert into genalpha.student_timeline (
      student_id,
      event_type,
      event_date,
      title,
      details,
      changed_by
    )
    values (
      new_row.id,
      'whatsapp_contact_blocked',
      current_date,
      case
        when new_row.whatsapp_contact_status = 'wrong_number' then 'WhatsApp number marked wrong'
        else 'WhatsApp reminders opted out'
      end,
      'Automatic WhatsApp reminders and queued retries were stopped. Update the contact status after the number is corrected.',
      v_actor
    );
  else
    update genalpha.reminder_events
    set
      status = case when status = 'manual_followup' then 'cancelled' else status end,
      manual_followup_required = false,
      manual_followup_reason = '',
      next_retry_at = null,
      retry_reason = 'WhatsApp contact reactivated. Future reminders may follow the normal schedule.'
    where student_id = new_row.id
      and manual_followup_reason in ('wrong_phone_number', 'whatsapp_opted_out');

    insert into genalpha.student_timeline (
      student_id,
      event_type,
      event_date,
      title,
      details,
      changed_by
    )
    values (
      new_row.id,
      'whatsapp_contact_reactivated',
      current_date,
      'WhatsApp contact reactivated',
      'The saved WhatsApp number is active again. Future reminders will follow the normal fee schedule.',
      v_actor
    );
  end if;

  return;
end;
$fn$;

revoke execute on function genalpha.sync_whatsapp_contact_followup(genalpha.students, genalpha.students, text) from public, anon;

create or replace function genalpha.log_student_life_timeline(
  new_row genalpha.students, old_row genalpha.students, p_op text default 'UPDATE'
)
returns void
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare
  v_actor text;
  v_changes text[];
  v_latest_renewal date;
begin
  if p_op = 'INSERT' then
    insert into genalpha.student_timeline (student_id, event_type, event_date, title, details, changed_by)
    values (
      new_row.id,
      'student_created',
      coalesce(new_row.join_date, current_date),
      'Player record created',
      concat('Joined ', coalesce(new_row.time_slot, 'slot not set'), '. Fee plan: ', coalesce(nullif(new_row.fee_plan, ''), 'monthly'), '.'),
      coalesce(nullif(new_row.added_by, ''), 'System')
    );
    return;
  end if;

  v_actor := coalesce(nullif(new_row.updated_by, ''), nullif(old_row.updated_by, ''), 'System');

  if new_row.discontinued is distinct from old_row.discontinued
     or new_row.discontinued_at is distinct from old_row.discontinued_at
     or new_row.rejoined_at is distinct from old_row.rejoined_at
     or new_row.fee_pause_days is distinct from old_row.fee_pause_days then
    insert into genalpha.student_timeline (student_id, event_type, event_date, title, details, changed_by)
    values (
      new_row.id,
      case when new_row.discontinued then 'student_discontinued' else 'student_rejoined' end,
      case
        when new_row.discontinued then coalesce(new_row.discontinued_at, current_date)
        else coalesce(new_row.rejoined_at, current_date)
      end,
      case when new_row.discontinued then 'Player discontinued' else 'Player marked active' end,
      case
        when new_row.discontinued then concat('Paused from ', coalesce(new_row.discontinued_at::text, current_date::text), '.')
        else concat(
          'Rejoined on ',
          coalesce(new_row.rejoined_at::text, current_date::text),
          '. Billing pause days: ',
          coalesce(new_row.fee_pause_days, 0),
          '.'
        )
      end,
      v_actor
    );
  end if;

  if new_row.renewals is distinct from old_row.renewals then
    v_latest_renewal := new_row.renewals[array_length(new_row.renewals, 1)];
    insert into genalpha.student_timeline (student_id, event_type, event_date, title, details, changed_by)
    values (
      new_row.id,
      'renewal_updated',
      current_date,
      'Renewal updated',
      concat('Latest renewal cycle date: ', coalesce(v_latest_renewal::text, 'not set'), '.'),
      v_actor
    );
  end if;

  if new_row.fees_paid is distinct from old_row.fees_paid
     or new_row.amount_paid is distinct from old_row.amount_paid
     or new_row.payment_status is distinct from old_row.payment_status
     or new_row.payment_reference is distinct from old_row.payment_reference then
    insert into genalpha.student_timeline (student_id, event_type, event_date, title, details, changed_by)
    values (
      new_row.id,
      'fee_status_updated',
      current_date,
      'Fee status updated',
      concat(
        'Status: ', case when new_row.fees_paid then 'Paid' else 'Not paid' end,
        '. Amount paid: Rs ', coalesce(new_row.amount_paid, 0),
        case when coalesce(nullif(new_row.payment_status, ''), '') <> '' then concat('. Payment status: ', new_row.payment_status) else '' end,
        case when coalesce(nullif(new_row.payment_reference, ''), '') <> '' then '. Reference saved.' else '' end
      ),
      v_actor
    );
  end if;

  if new_row.jersey_size is distinct from old_row.jersey_size
     or new_row.jersey_pairs is distinct from old_row.jersey_pairs
     or new_row.jersey_amount is distinct from old_row.jersey_amount then
    insert into genalpha.student_timeline (student_id, event_type, event_date, title, details, changed_by)
    values (
      new_row.id,
      'jersey_updated',
      current_date,
      'Jersey details updated',
      concat(
        'Size: ', coalesce(nullif(new_row.jersey_size, ''), 'not set'),
        '. Pairs: ', coalesce(new_row.jersey_pairs, 0),
        '. Amount: Rs ', coalesce(new_row.jersey_amount, 0), '.'
      ),
      v_actor
    );
  end if;

  v_changes := array_remove(array[
    case when new_row.name is distinct from old_row.name then 'name' end,
    case when new_row.age is distinct from old_row.age then 'age' end,
    case when new_row.time_slot is distinct from old_row.time_slot then 'time slot' end,
    case when new_row.join_date is distinct from old_row.join_date then 'join date' end,
    case when new_row.father_guardian_name is distinct from old_row.father_guardian_name then 'guardian' end,
    case when new_row.parent_contact_no is distinct from old_row.parent_contact_no then 'parent phone' end,
    case when new_row.alternate_contact_no is distinct from old_row.alternate_contact_no then 'alternate phone' end,
    case when new_row.school_college is distinct from old_row.school_college then 'school' end,
    case when new_row.grade is distinct from old_row.grade then 'grade' end,
    case when new_row.address is distinct from old_row.address then 'address' end,
    case when new_row.comments is distinct from old_row.comments then 'notes' end,
    case when new_row.fee_plan is distinct from old_row.fee_plan then 'fee plan' end,
    case when new_row.coaching_fee is distinct from old_row.coaching_fee then 'coaching fee' end,
    case when new_row.admission_fee is distinct from old_row.admission_fee then 'admission fee' end,
    case when new_row.total_fee_amount is distinct from old_row.total_fee_amount then 'total fee' end
  ], null);

  if array_length(v_changes, 1) is not null then
    insert into genalpha.student_timeline (student_id, event_type, event_date, title, details, changed_by)
    values (
      new_row.id,
      'profile_updated',
      current_date,
      'Player details updated',
      concat('Changed: ', array_to_string(v_changes, ', '), '.'),
      v_actor
    );
  end if;

  return;
end;
$fn$;

revoke execute on function genalpha.log_student_life_timeline(genalpha.students, genalpha.students, text) from public, anon;

create or replace function genalpha.log_student_payment_life_timeline(
  new_row genalpha.student_payments, old_row genalpha.student_payments, p_op text default 'UPDATE'
)
returns void
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare
  v_row genalpha.student_payments%rowtype;
  v_event_type text;
  v_title text;
  v_actor text;
begin
  if p_op = 'DELETE' then
    v_row := old_row;
    v_event_type := 'payment_deleted';
    v_title := case when old_row.payment_type = 'renewal' then 'Renewal payment deleted' else 'Payment deleted' end;
    v_actor := coalesce(nullif(old_row.recorded_by, ''), 'System');
  elsif p_op = 'UPDATE' then
    v_row := new_row;
    v_event_type := 'payment_updated';
    v_title := case when new_row.payment_type = 'renewal' then 'Renewal payment updated' else 'Payment updated' end;
    v_actor := coalesce(nullif(new_row.recorded_by, ''), 'System');
  else
    v_row := new_row;
    v_event_type := case
      when new_row.payment_type = 'joining' then 'joining_fee_paid'
      when new_row.payment_type in ('jersey', 'jersey_refund') then 'jersey_payment'
      else 'renewal_paid'
    end;
    v_title := case
      when new_row.payment_type = 'joining' then 'Joining fee recorded'
      when new_row.payment_type = 'renewal' then 'Renewal fee paid'
      when new_row.payment_type = 'jersey_refund' then 'Jersey refund recorded'
      when new_row.payment_type = 'jersey' then 'Jersey payment recorded'
      else 'Fee payment recorded'
    end;
    v_actor := coalesce(nullif(new_row.recorded_by, ''), 'System');
  end if;

  insert into genalpha.student_timeline (
    student_id,
    event_type,
    event_date,
    title,
    details,
    changed_by
  )
  values (
    v_row.student_id,
    v_event_type,
    coalesce(v_row.paid_on, current_date),
    v_title,
    concat(
      'Rs ', coalesce(v_row.amount, 0),
      ' • ', coalesce(nullif(v_row.plan_type, ''), 'plan not set'),
      ' • ', coalesce(v_row.months_covered, 0), ' month',
      case when coalesce(v_row.months_covered, 0) = 1 then '' else 's' end,
      ' • cycle from ', coalesce(v_row.cycle_start_date::text, 'not set'),
      case when coalesce(nullif(v_row.comment, ''), '') <> '' then concat(' • ', v_row.comment) else '' end,
      case when coalesce(nullif(v_row.proof_path, ''), '') <> '' then concat(' • payment-proofs/', v_row.proof_path) else '' end
    ),
    v_actor
  );

  if p_op = 'DELETE' then
    return;
  end if;
  return;
end;
$fn$;

revoke execute on function genalpha.log_student_payment_life_timeline(genalpha.student_payments, genalpha.student_payments, text) from public, anon;

create or replace function genalpha.preserve_admission_claim_payment_values(
  new_row genalpha.student_payments, old_row genalpha.student_payments, p_op text default 'UPDATE'
)
returns genalpha.student_payments
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare
  v_claim genalpha.admission_payment_claims%rowtype;
  v_admission genalpha.admissions%rowtype;
begin
  if new_row.payment_type <> 'joining' then
    return new_row;
  end if;

  select * into v_claim
  from genalpha.admission_payment_claims claim
  where claim.student_id = new_row.student_id
    and claim.verification_status in ('pending', 'conflict')
    and claim.student_payment_id is null
  order by claim.created_at
  limit 1
  for update;

  if not found then
    return new_row;
  end if;

  select * into v_admission
  from genalpha.admissions admission
  where admission.id = v_claim.admission_id;

  if found then
    new_row.plan_type := v_admission.fee_plan;
    new_row.cycle_start_date := v_admission.join_date;
    new_row.coaching_fee := v_admission.coaching_fee;
    new_row.admission_fee := v_admission.admission_fee;
    new_row.jersey_amount := v_admission.jersey_amount;
    new_row.total_fee_amount := v_admission.total_fee_amount;
    new_row.jersey_size := v_admission.jersey_size;
    new_row.jersey_pairs := v_admission.jersey_pairs;
  end if;

  new_row.amount := v_claim.amount;
  new_row.paid_on := coalesce(v_claim.payment_date, new_row.paid_on);
  new_row.proof_path := coalesce(nullif(v_claim.proof_path, ''), new_row.proof_path);
  new_row.payment_reference := coalesce(
    nullif(v_claim.payment_reference, ''),
    nullif(v_claim.utr, ''),
    new_row.payment_reference
  );

  return new_row;
end;
$fn$;

revoke execute on function genalpha.preserve_admission_claim_payment_values(genalpha.student_payments, genalpha.student_payments, text) from public, anon;

create or replace function genalpha.reconcile_admission_claim_from_payment(
  new_row genalpha.student_payments, old_row genalpha.student_payments, p_op text default 'UPDATE'
)
returns void
language plpgsql
security definer
set search_path = genalpha, public
as $fn$
declare
  v_claim_id uuid;
  v_admission_id uuid;
begin
  if new_row.payment_type <> 'joining' then return; end if;

  select c.id, c.admission_id into v_claim_id, v_admission_id
  from genalpha.admission_payment_claims c
  where c.student_id = new_row.student_id
    and c.verification_status in ('pending', 'conflict')
    and c.student_payment_id is null
  order by c.created_at
  limit 1
  for update;

  if v_claim_id is not null then
    update genalpha.admission_payment_claims
    set student_payment_id = new_row.id, verification_status = 'verified',
        verified_by = new_row.recorded_by, verified_at = now()
    where id = v_claim_id;

    update genalpha.admissions
    set fees_paid = true, amount_paid = new_row.amount,
        payment_verification_status = 'verified'
    where id = v_admission_id;
  end if;
  return;
end;
$fn$;

revoke execute on function genalpha.reconcile_admission_claim_from_payment(genalpha.student_payments, genalpha.student_payments, text) from public, anon;

-- ------------------------------------------------------------
-- 3. Call them from the triggers that already mediate these writes
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION genalpha.students_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare v_member bigint; v_uuid uuid;
begin
  if tg_op = 'DELETE' then
    select member_id into v_member from genalpha.student_details where legacy_uuid = old.id;
    -- tenant_id in the WHERE: ids are global (PLATFORM.md rule 2).
    delete from members where id = v_member and tenant_id = 'genalpha';
    return old;
  end if;

  -- The two BEFORE-trigger behaviours GenAlpha had on this table. They
  -- reshape the row, so the result is assigned back rather than the
  -- function mutating our `new` — it cannot.
  new := genalpha.ensure_student_pause_billing_fields(new, old, tg_op);
  if tg_op = 'UPDATE' then
    new := genalpha.set_student_reminder_pause_audit(new, old, tg_op);
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
    -- log_student_life_timeline, ported: this is why a player's history
    -- shows profile changes and not only payments.
    perform genalpha.log_student_life_timeline(new, old, 'INSERT');
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

  perform genalpha.log_student_life_timeline(new, old, 'UPDATE');
  -- Marking a number wrong or opted-out stops queued reminders and
  -- retries for that family. Without this the engine keeps chasing a
  -- number the academy already knows is bad.
  perform genalpha.sync_whatsapp_contact_followup(new, old, 'UPDATE');
  return new;
end $function$;

CREATE OR REPLACE FUNCTION genalpha.student_payments_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'genalpha', 'public'
AS $function$
declare
  v_member bigint; v_enroll bigint; v_months int; v_kind text; v_result jsonb; v_id bigint;
begin
  if tg_op = 'DELETE' then
    perform genalpha.log_student_payment_life_timeline(old, old, 'DELETE');
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
    new := genalpha.preserve_admission_claim_payment_values(new, old, 'UPDATE');
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
    perform genalpha.log_student_payment_life_timeline(new, old, 'UPDATE');
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
  -- record_fee_payment already writes its own 'payment' timeline entry,
  -- so this adds GenAlpha's richer one on top: the plan label, the cycle
  -- and who took it, which is what its history screen renders.
  perform genalpha.log_student_payment_life_timeline(new, new, 'INSERT');
  perform genalpha.reconcile_admission_claim_from_payment(new, new, 'INSERT');
  return new;
end $function$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare
  v_uuid uuid; v_member bigint; v_enroll bigint; v_pay text;
  t0 int; t1 int; n int; v_paused_by text; v_pause_days int;
begin
  -- All ten accounted for: eight helpers plus the two real triggers.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='genalpha' and p.proname in (
     'ensure_student_pause_billing_fields','set_student_reminder_pause_audit',
     'sync_whatsapp_contact_followup','log_student_life_timeline',
     'log_student_payment_life_timeline','preserve_admission_claim_payment_values',
     'reconcile_admission_claim_from_payment','guard_intake_admission_type',
     'link_admission_claim_to_approved_student');
  if n <> 9 then raise exception 'only % of 9 ported functions exist', n; end if;

  select count(*) into n from pg_trigger t
   where t.tgrelid = 'genalpha.admissions'::regclass and not t.tgisinternal;
  if n < 2 then raise exception 'genalpha.admissions has % triggers, expected at least 2', n; end if;

  -- ---- exercise them on a throwaway player ----
  select count(*) into t0 from genalpha.student_timeline;

  insert into genalpha.students
    (name, age, join_date, time_slot, fee_plan, coaching_fee, admission_fee,
     jersey_amount, total_fee_amount, jersey_size, jersey_pairs, renewals,
     added_by, updated_by, discontinued, father_guardian_name, parent_contact_no,
     whatsapp_contact_status, alternate_contact_no, fees_paid, amount_paid)
  values ('ZZ Trigger Probe', 9, current_date, '6AM', 'monthly', 3500, 500,
          0, 4000, 'M', 0, '[]'::jsonb, 'probe', 'probe', false,
          'ZZ Probe Parent', '9000000002', 'active', '', false, 0)
  returning id into v_uuid;
  select member_id into v_member from genalpha.student_details where legacy_uuid = v_uuid;

  -- log_student_life_timeline must have written something on INSERT
  select count(*) into t1 from genalpha.student_timeline where student_id = v_uuid;
  if t1 = 0 then raise exception 'log_student_life_timeline wrote nothing on insert'; end if;

  -- set_student_reminder_pause_audit: pausing must stamp who and when
  update genalpha.students
     set whatsapp_reminders_paused = true, updated_by = 'probe@example.invalid'
   where id = v_uuid;
  select whatsapp_reminders_paused_by into v_paused_by
    from genalpha.students where id = v_uuid;
  if v_paused_by is distinct from 'probe@example.invalid' then
    raise exception 'the reminder-pause audit did not stamp the actor (got %)', v_paused_by;
  end if;

  -- ensure_student_pause_billing_fields: discontinuing then rejoining
  -- must accumulate the paused days rather than leave them at zero
  update genalpha.students set discontinued = true, discontinued_at = current_date - 10
   where id = v_uuid;
  update genalpha.students set discontinued = false where id = v_uuid;
  select fee_pause_days into v_pause_days from genalpha.students where id = v_uuid;
  if coalesce(v_pause_days, 0) < 10 then
    raise exception 'rejoining did not accumulate the pause days (got %)', v_pause_days;
  end if;

  -- sync_whatsapp_contact_followup: a wrong number must land in the timeline
  update genalpha.students set whatsapp_contact_status = 'wrong_number',
                               updated_by = 'probe@example.invalid'
   where id = v_uuid;
  if not exists (select 1 from genalpha.student_timeline
                  where student_id = v_uuid and event_type = 'whatsapp_contact_blocked') then
    raise exception 'marking a number wrong wrote no timeline entry';
  end if;
  update genalpha.students set whatsapp_contact_status = 'active' where id = v_uuid;
  if not exists (select 1 from genalpha.student_timeline
                  where student_id = v_uuid and event_type = 'whatsapp_contact_reactivated') then
    raise exception 'reactivating the number wrote no timeline entry';
  end if;

  -- log_student_payment_life_timeline, through a real payment
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, joined_on, renewal_on, status)
  select 'genalpha', v_member, e.centre_id, e.batch_id, 'cricket',
         1, current_date, current_date, 'active'
    from enrollments e where e.tenant_id='genalpha' order by e.id limit 1;

  insert into genalpha.student_payments
    (student_id, payment_type, plan_type, cycle_start_date, months_covered,
     amount, paid_on, comment, recorded_by)
  values (v_uuid, 'renewal', 'monthly', current_date, 1, 3500, current_date,
          'probe', 'probe@example.invalid')
  returning id into v_pay;

  if not exists (select 1 from genalpha.student_timeline
                  where student_id = v_uuid
                    and event_type in ('renewal_paid','payment_recorded','payment_updated')) then
    raise exception 'the payment wrote no GenAlpha timeline entry';
  end if;

  -- ---- clean up completely ----
  delete from payments        where member_id = v_member;
  delete from member_timeline where member_id = v_member;
  delete from enrollments     where member_id = v_member;
  delete from genalpha.students where id = v_uuid;

  select count(*) into t1 from genalpha.student_timeline;
  if t1 <> t0 then raise exception 'the probe left % timeline rows behind', t1 - t0; end if;
  if exists (select 1 from members where id = v_member) then
    raise exception 'the probe player survived cleanup';
  end if;

  raise notice 'all ten triggers ported and exercised: profile history, pause audit, '
               'pause-day accrual, contact follow-up, payment history';
end $$;
