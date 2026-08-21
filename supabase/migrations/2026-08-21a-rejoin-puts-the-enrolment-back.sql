-- ============================================================
-- 2026-08-21a · A rejoined player is only rejoined if the enrolment says so
-- scope: shared
--
-- Marking a player rejoined moved members.status back to 'active' and left
-- public.enrollments.status at 'discontinued', because students_write updated
-- members and student_details and never touched the enrolment at all.
--
-- reminder_queue() filters on BOTH:
--
--     and e.status = 'active'
--     and m.status <> 'discontinued'
--
-- so the player disappears from the fee chase while every screen shows them
-- active. Sriramineni Dhruvan rejoined on 2026-08-17, paid on the 20th, and
-- would never have been reminded again. Kruthik C is the mirror image:
-- discontinued on the member, still 'active' on the enrolment, renewal_on
-- 2026-07-29 and overdue.
--
-- Nothing about money changes here. record_fee_payment is untouched, and the
-- rule it documents -- "paying late never back-dates coverage over a period
-- the student already sat through unpaid" -- still stands. What changes is
-- that a break is not treated as such a period: on return, the fee falls due
-- from the rejoin date unless the player is already paid beyond it.
-- ============================================================

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

  -- THE ENROLMENT IS WHERE reminder_queue LOOKS. It filters on
  -- `e.status = 'active' and m.status <> 'discontinued'`, and this trigger
  -- used to move only the member, so a rejoined player stayed 'discontinued'
  -- on their enrolment and was never chased for a fee again -- silently, with
  -- the app showing them as active. Sriramineni Dhruvan sat in exactly that
  -- state, and Kruthik C in the mirror image of it.
  --
  -- `new.discontinued is null` means the caller is not touching the status at
  -- all, so neither does this.
  if new.discontinued is not null then
    update enrollments e
       set status = case when new.discontinued then 'discontinued' else 'active' end,
           discontinued_on = case when new.discontinued
                                  then coalesce(new.discontinued_at, e.discontinued_on, current_date)
                                  else null end,
           -- A break is not chargeable, so on return the fee falls due from
           -- the rejoin date -- unless the player is already paid beyond it,
           -- in which case that later date stands. This is the same rule the
           -- apps apply as rejoinAwarePaidThroughDate.
           renewal_on = case
             when new.discontinued then e.renewal_on
             when new.rejoined_at is not null
               then greatest(coalesce(e.renewal_on, new.rejoined_at), new.rejoined_at)
             else e.renewal_on end,
           updated_at = now()
     where e.member_id = v_member and e.tenant_id = 'genalpha';
  end if;

  perform genalpha.log_student_life_timeline(new, old, 'UPDATE');
  -- Marking a number wrong or opted-out stops queued reminders and
  -- retries for that family. Without this the engine keeps chasing a
  -- number the academy already knows is bad.
  perform genalpha.sync_whatsapp_contact_followup(new, old, 'UPDATE');
  return new;
end $function$
;


-- ------------------------------------------------------------
-- The two players already in the split state. Guarded to rows where the
-- enrolment genuinely disagrees with the member, so re-running is a no-op.
-- ------------------------------------------------------------
update enrollments e
   set status = case when m.status = 'discontinued' then 'discontinued' else 'active' end,
       discontinued_on = case when m.status = 'discontinued'
                              then coalesce(e.discontinued_on, m.discontinued_on, current_date)
                              else null end,
       renewal_on = case
         when m.status <> 'discontinued' and m.rejoined_at is not null
           then greatest(coalesce(e.renewal_on, m.rejoined_at), m.rejoined_at)
         else e.renewal_on end,
       updated_at = now()
  from members m
 where m.id = e.member_id
   and m.tenant_id = 'genalpha'
   and e.tenant_id = 'genalpha'
   and m.status <> e.status;

do $$
declare v_split int; v_dhruvan text;
begin
  select count(*) into v_split
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.status <> e.status;
  if v_split > 0 then
    raise exception '% players still have an enrolment that disagrees with them', v_split;
  end if;

  select e.status into v_dhruvan
    from members m join enrollments e on e.member_id = m.id
   where m.tenant_id = 'genalpha' and m.name = 'Sriramineni Dhruvan';
  if v_dhruvan <> 'active' then
    raise exception 'Dhruvan enrolment is %, expected active', v_dhruvan;
  end if;

  if not exists (select 1 from reminder_queue('genalpha') q
                  where q.member_name = 'Sriramineni Dhruvan')
     and (select e.renewal_on from members m join enrollments e on e.member_id = m.id
           where m.tenant_id='genalpha' and m.name='Sriramineni Dhruvan') <= ist_today() then
    raise exception 'Dhruvan is due but still not in the reminder queue';
  end if;

  raise notice 'enrolments now follow the member through discontinue and rejoin';
end $$;
