-- ============================================================
-- 2026-08-31c · A Pay Now tap stops claiming screenshots after three days
-- scope: shared
--
-- karthikeya's parent paid tonight and sent the screenshot. It arrived, the
-- reply went out, the manager alert was delivered with the proof — and the
-- app showed "renewal overdue" with no Confirm button.
--
-- selectPaymentConversationReminder prefers a reminder whose Pay Now
-- conversation is ACTIVE over the newest daily reminder, which is right: the
-- cron often creates a fresher reminder between the tap and the screenshot.
-- It had no time bound, so the preference never expired. He tapped Pay Now on
-- 21 July and never finished; that reminder sat in payment_attempted, and six
-- weeks later tonight's proof was welded onto it.
--
-- The August reminder therefore stayed 'delivered', and the pending payment
-- landed on a cycle whose due date (21 Jul) is before the current cycle
-- started. The cycle gate then did exactly its job and refused to show a
-- stale follow-up — which is why there was no Confirm button and why
-- confirming from the app did nothing.
--
-- The window is now three days (conversation_routing.ts). This closes the
-- eleven reminders already sitting in an active payment status, EVERY one of
-- them stale, on a cycle that has since been paid — 8 to 123 days old. Each
-- was a screenshot waiting to be misfiled the same way.
-- ============================================================

-- ------------------------------------------------------------
-- 1. karthikeya's screenshot belongs to the August cycle.
-- ------------------------------------------------------------
do $$
declare v_moved int;
begin
  update genalpha.reminder_events
     set status                          = 'payment_pending_verification',
         payment_pending_verification_at = (select payment_pending_verification_at
                                              from genalpha.reminder_events where id = '2633'),
         amount                          = (select amount from genalpha.reminder_events where id = '2633'),
         selected_plan                   = (select selected_plan from genalpha.reminder_events where id = '2633'),
         manager_payment_alert_status    = (select manager_payment_alert_status
                                              from genalpha.reminder_events where id = '2633'),
         manager_payment_alert_sent_at   = (select manager_payment_alert_sent_at
                                              from genalpha.reminder_events where id = '2633')
   where id = '2929';

  -- 2633's own July cycle was paid on 31 July (payment 3551), so it closes
  -- confirmed. Tonight's claim fields go with it.
  update genalpha.reminder_events
     set status                          = 'payment_confirmed',
         payment_pending_verification_at = null,
         manager_payment_alert_status    = null,
         manager_payment_alert_sent_at   = null
   where id = '2633';

  update genalpha.wa_flow_event_details
     set reminder_event_id = 2929
   where flow_event_id = 7106;
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'expected to move 1 proof event, moved %', v_moved;
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. Every other reminder left holding an expired Pay Now conversation.
--    Only where the cycle has since been paid, so nothing owed is closed.
-- ------------------------------------------------------------
update genalpha.reminder_events r
   set status = 'payment_confirmed'
  from genalpha.students s
 where s.id = r.student_id
   and r.status in ('payment_attempted', 'payment_pending_verification')
   and r.due_date < ist_today() - 5
   and genalpha.student_paid_through_date(s.id) > r.due_date;

do $$
declare v_stale int; v_status text; v_link bigint; v_old text;
begin
  -- Measured the way the code measures it: how old the CONVERSATION is, not
  -- how old the cycle is. An earlier version of this check used due_date and
  -- flagged the very row this migration had just repaired — karthikeya's
  -- August reminder is due 21 Aug but its proof arrived tonight, which is
  -- exactly the state we want.
  select count(*) into v_stale
    from genalpha.reminder_events r
   where r.status in ('payment_attempted','payment_pending_verification')
     and now() - coalesce(r.payment_pending_verification_at, r.payment_attempted_at,
                          r.manager_payment_alert_due_at, r.created_at) > interval '3 days';
  if v_stale > 0 then
    raise exception '% reminders still hold an expired Pay Now conversation', v_stale;
  end if;

  select status into v_status from genalpha.reminder_events where id = '2929';
  if v_status <> 'payment_pending_verification' then
    raise exception 'the August reminder reads %, expected payment_pending_verification', v_status;
  end if;

  select status into v_old from genalpha.reminder_events where id = '2633';
  if v_old <> 'payment_confirmed' then
    raise exception 'the July reminder reads %, expected payment_confirmed', v_old;
  end if;

  select reminder_event_id into v_link
    from genalpha.wa_flow_event_details where flow_event_id = 7106;
  if v_link <> 2929 then
    raise exception 'the screenshot still points at reminder %', v_link;
  end if;

  raise notice 'karthikeya is pending confirmation on the August cycle; 11 stale conversations closed';
end $$;
