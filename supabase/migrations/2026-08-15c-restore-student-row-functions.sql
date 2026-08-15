-- ============================================================
-- 2026-08-15c · Restore the four student-row functions CASCADE dropped
-- scope: shared
--
-- Saving a renewal from the UI fails with:
--   function genalpha.ensure_student_pause_billing_fields(students, students, text)
--   does not exist
-- and the payment row is written while the player's renewal status is not.
--
-- 2026-08-12g needed to rebuild genalpha.students to mask contact details for
-- the coach role, and did `drop view if exists genalpha.students cascade`. These
-- four functions take genalpha.students as a parameter type, so they depend on
-- the view's composite rowtype and CASCADE took them with it. The view was
-- recreated; they were not. The students_write trigger still calls them, so
-- every update through the view has failed since.
--
-- Recreated verbatim from 2026-08-11zs, which is still their source of truth.
--
-- Note for anyone rebuilding genalpha.students again: dropping it CASCADE
-- silently removes every function typed over its rowtype. Re-run this file, or
-- fold these definitions into that migration.
-- ============================================================

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

-- ------------------------------------------------------------
-- Checks: all four back, and an update through the view survives.
-- ------------------------------------------------------------
do $$
declare
  r        record;
  v_missing text := '';
  v_id     uuid;
  v_before text;
begin
  for r in
    select unnest(array[
      'ensure_student_pause_billing_fields',
      'set_student_reminder_pause_audit',
      'sync_whatsapp_contact_followup',
      'log_student_life_timeline'
    ]) as name
  loop
    if not exists (
      select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'genalpha' and p.proname = r.name
    ) then
      v_missing := v_missing || r.name || ' ';
    end if;
  end loop;
  if v_missing <> '' then
    raise exception 'still missing after restore: %', v_missing;
  end if;

  -- The real proof: the trigger path that was failing must now complete.
  select id, updated_by into v_id, v_before from genalpha.students limit 1;
  if v_id is null then
    raise notice 'no students to prove the update path against';
    return;
  end if;
  update genalpha.students set updated_by = coalesce(v_before, '') where id = v_id;
  update genalpha.students set updated_by = v_before where id = v_id;
  raise notice 'student update through the view completes again';
end $$;
