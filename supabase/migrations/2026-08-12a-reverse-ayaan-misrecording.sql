-- ============================================================
-- 2026-08-12a · Reverse three renewals recorded in error
-- scope: shared
--
-- Player F had three renewals recorded within sixty seconds on
-- 2026-08-11 (payments 3642, 3643, 3644 — Rs 3,000 each, Rs 9,000 total).
-- The academy owner confirms none of them is a real payment. Two were
-- already deleted from the app, which voided them; one is still paid.
--
-- They left four marks, and voiding only addressed the first:
--
--   enrollments.renewal_on           2026-10-11, two months past the truth
--   student_details.renewals         three cycle dates appended
--   reminder_events.status           flipped to payment_confirmed
--   member_timeline                  a run of payment / voided entries
--
-- WHAT IT GOES BACK TO. 2026-08-03. That is the due_date on today's
-- reminder for this player, written before any of the three, and it
-- matches the two surviving pending_verification payments from the
-- merge — so it is the value the reminder ladder itself was working
-- from, not a guess.
--
-- DELETED, NOT VOIDED. void_payment exists so a REAL payment recorded
-- against the wrong family or the wrong month leaves a trail. These were
-- never payments; keeping three voided rows on a family's financial
-- history to record that a button misfired makes the history harder to
-- read, not easier. This migration is the audit trail.
--
-- The three carried no proof_path, no ref and no reminder link, so
-- nothing outside these tables references them.
-- ============================================================

do $$
declare
  v_member bigint; v_enroll bigint; n int; v_read timestamptz; v_delivered timestamptz;
  v_money_before numeric; v_money_after numeric;
begin
  select m.id, e.id into v_member, v_enroll
    from members m join enrollments e on e.member_id = m.id and e.tenant_id = 'genalpha'
   where m.tenant_id = 'genalpha' and m.name = 'Player F';
  if v_member is null then raise exception 'Player F not found'; end if;

  select sum(amount) into v_money_before from payments where tenant_id = 'genalpha';

  -- Guard: only ever the three from that minute, never the migrated
  -- history. If the shape is not exactly what was inspected, stop.
  select count(*) into n from payments
   where id in (3642, 3643, 3644) and member_id = v_member and tenant_id = 'genalpha'
     and amount = 3000 and kind = 'renewal';
  if n <> 3 then
    raise exception 'expected exactly 3 matching payments to remove, found %', n;
  end if;

  delete from member_timeline
   where tenant_id = 'genalpha' and member_id = v_member
     and (meta->>'payment_id')::bigint in (3642, 3643, 3644);
  delete from member_timeline
   where tenant_id = 'genalpha' and member_id = v_member
     and at >= '2026-08-11 12:30:00+00'
     and kind in ('payment', 'payment_pending', 'note', 'renewal_paid',
                  'payment_deleted', 'renewal_whatsapp_confirmation');

  delete from payments where id in (3642, 3643, 3644);

  -- Coverage back to what the reminder ladder was working from.
  update enrollments set renewal_on = date '2026-08-03' where id = v_enroll;

  -- The renewals array gained one entry per recording.
  update genalpha.student_details
     set renewals = (
       select coalesce(jsonb_agg(x order by x), '[]'::jsonb)
         from jsonb_array_elements_text(renewals) x
        where x not in ('2026-08-03', '2026-09-03', '2026-10-11'))
   where member_id = v_member;

  -- The reminder goes back to how far it actually got: Meta delivered it
  -- and the parent read it. Nothing was paid.
  select d.read_at, d.delivered_at into v_read, v_delivered
    from genalpha.reminder_event_details d
    join reminder_events r on r.id = d.reminder_event_id
   where r.member_id = v_member and r.ist_date = date '2026-08-11'
   order by r.id desc limit 1;

  update reminder_events
     set status = case when v_read is not null then 'read'
                       when v_delivered is not null then 'delivered'
                       else 'accepted' end
   where member_id = v_member and ist_date = date '2026-08-11';

  update genalpha.reminder_event_details d
     set payment_confirmed_at = null,
         payment_attempted_at = null,
         payment_pending_verification_at = null
    from reminder_events r
   where r.id = d.reminder_event_id
     and r.member_id = v_member and r.ist_date = date '2026-08-11';

  select sum(amount) into v_money_after from payments where tenant_id = 'genalpha';
  raise notice 'removed Rs % of mis-recorded payments (% -> %)',
    v_money_before - v_money_after, v_money_before, v_money_after;
end $$;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v_member bigint; n int; v_renewal date; v_status text; v_renewals jsonb;
begin
  select m.id into v_member from members m
   where m.tenant_id='genalpha' and m.name='Player F';

  if exists (select 1 from payments where id in (3642,3643,3644)) then
    raise exception 'a mis-recorded payment survived'; end if;

  -- His real history must be untouched: TWO pending_verification rows
  -- from the merge (3591, 3592) and nothing else.
  --
  -- Two, not three. The query used to inspect this matched on
  -- name like 'Ayaan%', which also caught Player C — a
  -- different child, whose payment 3519 sat in the same listing. The
  -- delete was always by id so it was never at risk, but it is worth
  -- recording that two players here share a name prefix.
  select count(*) into n from payments where member_id = v_member;
  if n <> 2 then raise exception 'Player F now has % payments, expected his 2 migrated rows', n; end if;
  select count(*) into n from payments where member_id = v_member and status='pending_verification';
  if n <> 2 then raise exception 'his migrated payments changed status'; end if;

  -- and the other child is untouched
  if not exists (select 1 from payments p join members m on m.id=p.member_id
                  where m.name='Player C' and p.id=3519
                    and p.status='pending_verification') then
    raise exception 'Player C''s payment was affected';
  end if;

  select renewal_on into v_renewal from enrollments where member_id = v_member and tenant_id='genalpha';
  if v_renewal <> date '2026-08-03' then
    raise exception 'renewal_on is %, expected 2026-08-03', v_renewal; end if;

  select renewals into v_renewals from genalpha.student_details where member_id = v_member;
  if v_renewals ? '2026-10-11' or v_renewals ? '2026-09-03' then
    raise exception 'the renewals array still holds a mis-recorded cycle: %', v_renewals; end if;

  select status into v_status from reminder_events
   where member_id = v_member and ist_date = date '2026-08-11';
  if v_status = 'payment_confirmed' then
    raise exception 'the reminder still claims a confirmed payment'; end if;
  raise notice 'his reminder reads % again', v_status;

  -- and he is back in the queue, which is the point
  if not exists (select 1 from reminder_queue('genalpha') q where q.member_id = v_member) then
    raise notice 'note: he is not in reminder_queue today — check the ladder rung';
  end if;

  -- nobody else moved
  select count(*) into n from payments where tenant_id='genalpha';
  raise notice 'genalpha now has % payments, Rs %', n,
    (select sum(amount) from payments where tenant_id='genalpha');
end $$;
