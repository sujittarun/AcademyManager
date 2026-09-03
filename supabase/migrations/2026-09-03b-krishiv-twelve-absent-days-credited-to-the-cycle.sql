-- ============================================================
-- 2026-09-03b · Krishiv: twelve absent days credited to the current cycle
-- scope: shared (writes enrollments + member_timeline)
--
-- "Krishiv has not come to coaching for 12 days. pause/move his cycle time,
--  just add 12+ for current cycle and show the overdue date, but from next
--  month consider 30 days cycle only from the end of updated current cycle.
--  this is not new rule just 1 back end change"
--
-- Krishiv Reddy Ravula, enrolment 1597, ₹10,000 special plan. His cycle ran
-- out on 11 Aug; today is 3 Sep, so he reads 23 days overdue and the ladder
-- handed him to manual follow-up on 25 Aug after eleven WhatsApp messages
-- for that date. The academy has agreed with the family that the twelve
-- days he did not attend are theirs, not owed.
--
-- ONE COLUMN MOVES. enrollments.renewal_on 2026-08-11 -> 2026-08-23, and
-- everything that quotes a date already reads it:
--
--   reminder_queue()          due_date = renewal_on   -> chases from 23 Aug
--   genalpha.quote_fee()      paid_through            -> the renewal sheet
--   genalpha.students         paid_through            -> web app, WhatsApp
--   record_fee_payment()      period_from = renewal_on when a fee exists,
--                             so the NEXT payment buys 23 Aug -> 23 Sep.
--                             That is the "30 days from the end of the
--                             updated cycle" clause, and it is the chain
--                             rule 2026-08-31d made global — nothing new.
--
-- The Android app is the one reader that does NOT take this column; it
-- recomputes the date from the renewals array and would keep saying 11 Aug.
-- Fixed in GenAlphaApp 1.0.79 by reading paid_through first, the way the web
-- app and the sender have since b7c2435.
--
-- NOT A NEW RULE, ON PURPOSE. The platform has no "extend a cycle by N days"
-- function, and 2026-08-24c explains why: a pause length guessed on the day
-- is a money value written from a guess. This is a manager's settled fact
-- about one player, so it is a guarded UPDATE with a timeline row, and it
-- refuses to run against anything but the exact state it was written for.
--
-- WHAT THE LADDER DOES NEXT. Today's 15:00 IST run has already fired. From
-- tomorrow he is 12 days past 23 Aug, inside the +7..14 daily band, so the
-- parent gets a chase on 4, 5 and 6 Sep quoting 23 Aug, then manual again
-- on the 7th. The 25 Aug manual-follow-up row is for the 11 Aug cycle and
-- both apps drop it as stale (isFollowUpForCurrentCycle: due < cycle).
-- ============================================================

do $$
declare
  v_enrol   bigint := 1597;                                       -- Krishiv Reddy Ravula
  v_member  bigint := 1717;
  v_student uuid   := '1f835dc8-8f47-4f92-bccf-9d0ff51268e5';
  v_from    date   := date '2026-08-11';
  v_to      date   := date '2026-08-23';                          -- + 12 absent days
  b record; q record; v_pt date;
begin
  select m.name, m.rejoined_at, e.status, e.renewal_on, e.joined_on,
         (select count(*) from payments p
           where p.enrollment_id = e.id and p.status = 'paid' and p.period_to > v_from) as paid_past_11aug
    into b
  from enrollments e join members m on m.id = e.member_id
  where e.id = v_enrol and e.tenant_id = 'genalpha' and e.member_id = v_member;

  if not found then
    raise exception 'enrolment % / member % is not Krishiv''s genalpha enrolment', v_enrol, v_member;
  end if;
  if b.name not ilike 'Krishiv%' then
    raise exception 'enrolment % is %, not Krishiv', v_enrol, b.name;
  end if;
  if b.status <> 'active' then
    raise exception 'Krishiv is %, not active — a cycle is only extended for a player who is training', b.status;
  end if;
  if b.renewal_on <> v_from then
    raise exception 'renewal_on is %, expected % — already moved, or a fee landed. Look before re-running.', b.renewal_on, v_from;
  end if;
  if b.paid_past_11aug <> 0 then
    raise exception 'a paid fee already covers past 11 Aug — extending the cycle now would double-credit';
  end if;
  if b.rejoined_at is not null then
    -- Every client reads paid_through first ONLY when there is no rejoin; with
    -- one set they fall back to their own arithmetic and this move would be
    -- invisible on screen. He has none, and this makes sure of it.
    raise exception 'rejoined_at is set (%) — the clients would not show the moved date', b.rejoined_at;
  end if;

  update enrollments
     set renewal_on = v_to, updated_at = now()
   where id = v_enrol and tenant_id = 'genalpha';

  -- data_correction is a kept, protected "life" row in both apps' timeline
  -- rules, so this is visible and never folded away.
  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values ('genalpha', v_member, v_enrol, 'data_correction',
          'Fee cycle extended by 12 days',
          'Krishiv did not attend for 12 days, so the current cycle now runs to 23 Aug 2026 '
          || 'instead of 11 Aug. The next renewal covers 23 Aug – 23 Sep.',
          jsonb_build_object('event_date', ist_today(), 'changed_by', 'migration 2026-09-03b',
                             'renewal_on_before', v_from, 'renewal_on', v_to, 'absent_days', 12));

  -- ---- read-only proof that every reader now says 23 Aug ----
  select renewal_on into v_pt from enrollments where id = v_enrol;
  if v_pt <> v_to then raise exception 'renewal_on is % after the update', v_pt; end if;

  select paid_through into v_pt from genalpha.students where id = v_student;
  if v_pt <> v_to then raise exception 'genalpha.students.paid_through is % — the apps would show the old date', v_pt; end if;

  if (genalpha.quote_fee(v_student, 1)->>'paid_through')::date <> v_to then
    raise exception 'quote_fee paid_through is % — the renewal sheet would pre-fill from the old cycle',
                    genalpha.quote_fee(v_student, 1)->>'paid_through';
  end if;

  select due_date, days_since, stage into q
    from reminder_queue('genalpha') where member_name = b.name;
  if not found then
    raise exception 'Krishiv fell out of reminder_queue — he is overdue and must be in it';
  end if;
  if q.due_date <> v_to then
    raise exception 'reminder_queue quotes % — the parent would be chased for the old date', q.due_date;
  end if;
  if q.days_since <> (ist_today() - v_to) then
    raise exception 'reminder_queue days_since=% but today - 23 Aug = %', q.days_since, ist_today() - v_to;
  end if;

  raise notice 'Krishiv: cycle 11 Aug -> 23 Aug; queue says due % (% days), stage %',
               q.due_date, q.days_since, q.stage;
end $$;
