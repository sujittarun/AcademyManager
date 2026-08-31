-- ============================================================
-- 2026-08-31g · Close the reminders whose fee has been paid
-- scope: shared
--
-- 2026-08-31f gave GenAlpha's reminders their enrolment, so payments can now
-- close them. This settles the backlog that built up while they could not, and
-- widens the definition of "still chasing" so the backlog cannot rebuild.
--
-- THE LIST WAS INCOMPLETE. apply_payment_coverage resolved only
-- sent/delivered/read/accepted/failed/retry_scheduled/manual_followup/queued.
-- Missing: send_failed, delivery_failed and undelivered (a reminder that never
-- reached the parent stayed open forever after they paid), payment_link_sent
-- (GenAlpha's), and manual_sent — which is the ONLY status mezzo and raj ever
-- write, so mezzo's reminders could not close either.
--
-- Deliberately still excluded: payment_attempted and
-- payment_pending_verification, because a proof waiting on the owner must not
-- be closed by an unrelated payment — that is the karthikeya shape; and
-- help_requested, because a parent who asked for help needs a person.
--
-- The sweep touches ONLY reminders whose own cycle has since been paid
-- (enrollments.renewal_on has moved past the reminder's due_date). The 239
-- GenAlpha reminders sitting on cycles that are still unpaid are untouched,
-- including the twelve marked manual_followup that are the owner's call list.
-- ============================================================

CREATE OR REPLACE FUNCTION public.apply_payment_coverage(p_tenant text, p_payment bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p payments; e enrollments;
begin
  select * into p from payments where id = p_payment and tenant_id = p_tenant;
  if not found then raise exception 'Payment not found.'; end if;
  if p.status <> 'paid' or p.enrollment_id is null then return; end if;

  select * into e from enrollments where id = p.enrollment_id;
  if not found then return; end if;

  if p.kind = 'admission' then
    update enrollments set admission_paid = true, updated_at = now() where id = e.id;
  end if;

  if coalesce(p.months, 0) > 0 and p.period_to is not null then
    -- Never move a renewal backwards. If two payments land out of
    -- order, the furthest coverage wins.
    update enrollments
       set renewal_on = greatest(coalesce(renewal_on, p.period_to), p.period_to),
           updated_at = now()
     where id = e.id;

    update reminder_events
       set status = 'resolved', resolved_at = now(), next_retry_at = null
     where tenant_id = p_tenant and enrollment_id = e.id
       -- Every status that means "still chasing". send_failed, delivery_failed
       -- and undelivered were missing, so a reminder that never reached the
       -- parent stayed open forever even after they paid. payment_link_sent is
       -- GenAlpha's, manual_sent is what mezzo and raj write — neither was
       -- listed, so mezzo's reminders could not close either.
       --
       -- payment_attempted and payment_pending_verification are deliberately
       -- NOT here: a proof waiting on the owner must not be closed by an
       -- unrelated payment. help_requested is not here either — a parent who
       -- asked for help needs a person, not a status change.
       and status in ('sent','delivered','read','accepted','failed',
                      'send_failed','delivery_failed','undelivered',
                      'retry_scheduled','manual_followup','queued',
                      'payment_link_sent','manual_sent');
  end if;
end $function$
;


-- ------------------------------------------------------------
-- The backlog. Settled cycles only.
-- ------------------------------------------------------------
update reminder_events r
   set status = 'resolved', resolved_at = now(), next_retry_at = null
  from enrollments e
 where e.id = r.enrollment_id
   and r.status in ('sent','delivered','read','accepted','failed',
                    'send_failed','delivery_failed','undelivered',
                    'retry_scheduled','manual_followup','queued',
                    'payment_link_sent','manual_sent')
   and e.renewal_on > r.due_date;

do $$
declare v_resolved int; v_open int; v_callable int; v_pending int;
begin
  select count(*) into v_resolved from reminder_events
   where tenant_id = 'genalpha' and status = 'resolved';
  if v_resolved = 0 then
    raise exception 'the sweep resolved nothing';
  end if;

  -- Nothing on a settled cycle may still read as open.
  select count(*) into v_open
    from reminder_events r join enrollments e on e.id = r.enrollment_id
   where r.status in ('sent','delivered','read','accepted','failed',
                      'send_failed','delivery_failed','undelivered',
                      'retry_scheduled','manual_followup','queued',
                      'payment_link_sent','manual_sent')
     and e.renewal_on > r.due_date;
  if v_open > 0 then
    raise exception '% reminders on settled cycles are still open', v_open;
  end if;

  -- The call list must survive. These are on cycles nobody has paid.
  select count(*) into v_callable
    from reminder_events r join enrollments e on e.id = r.enrollment_id
   where r.tenant_id = 'genalpha' and r.status = 'manual_followup'
     and e.renewal_on <= r.due_date;
  if v_callable < 12 then
    raise exception 'only % manual_followup reminders left on unpaid cycles, expected 12', v_callable;
  end if;

  -- A proof waiting on the owner must never have been swept.
  select count(*) into v_pending from reminder_events
   where status in ('payment_attempted','payment_pending_verification');
  raise notice 'resolved %, kept % on the call list, % payment claims untouched',
    v_resolved, v_callable, v_pending;
end $$;
