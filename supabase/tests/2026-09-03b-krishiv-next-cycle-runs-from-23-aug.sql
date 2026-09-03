-- ============================================================
-- Behaviour test for 2026-09-03b — the next fee runs from the moved date
--
-- Run inside `begin; <migration>; <this>; rollback;`.
--
-- The migration proves the READERS quote 23 Aug. This proves the WRITER
-- does: the next payment, whenever it lands, must buy 23 Aug -> 23 Sep and
-- leave renewal_on on 23 Sep. That is the second half of the request —
-- "from next month consider 30 days cycle only from the end of updated
-- current cycle" — and it comes from the chain rule, not from this file, so
-- the test is what proves nothing else was needed.
-- ============================================================
-- K0 · the WhatsApp/AgentAlpha path: a claim recorded as pending_verification,
--      then confirmed by the manager. Runs first, inside a sub-transaction that
--      is rolled back on its own sentinel, so K1/K2 still start from 23 Aug.
do $$
declare v_pid bigint; r jsonb; p payments; v_ren date;
begin
  begin
    r := record_fee_payment('genalpha', 1597, 10000, 1, 'UPI', 'renewal', ist_today(),
                            null, 'pending_verification', 'AgentAlpha', 'K0 probe');
    v_pid := (r->>'payment_id')::bigint;
    select renewal_on into v_ren from enrollments where id = 1597;
    if v_ren <> date '2026-08-23' then
      raise exception 'K0 a pending claim moved the cycle before confirmation: %', v_ren;
    end if;
    perform confirm_payment('genalpha', v_pid);
    select * into p from payments where id = v_pid;
    select renewal_on into v_ren from enrollments where id = 1597;
    if (p.period_from, p.period_to, v_ren) is distinct from (date '2026-08-23', date '2026-09-23', date '2026-09-23') then
      raise exception 'K0 confirmed claim ran % -> %, renewal_on % (expected 23 Aug -> 23 Sep -> 23 Sep)',
                      p.period_from, p.period_to, v_ren;
    end if;
    raise exception using errcode = 'P0999', message = 'K0_DONE';
  exception when sqlstate 'P0999' then null;   -- roll the probe back, keep the verdict
  end;
  raise notice 'krishiv confirm-path block passed (K0)';
end $$;

do $$
declare
  v_enrol bigint := 1597; r jsonb; p payments; v_ren date; fails text[] := '{}';
begin
  -- K1 · paid today (3 Sep, 11 days late): the cycle continues from 23 Aug.
  --      Late does not buy the lapse.
  r := record_fee_payment('genalpha', v_enrol, 10000, 1, 'UPI', 'renewal', ist_today());
  select * into p from payments where id = (r->>'payment_id')::bigint;
  select renewal_on into v_ren from enrollments where id = v_enrol;

  if p.period_from <> date '2026-08-23' then
    fails := fails || format('K1 period_from=%s — the next fee did not start where the extended cycle ended', p.period_from);
  end if;
  if p.period_to <> date '2026-09-23' then
    fails := fails || format('K1 period_to=%s — one month from 23 Aug is 23 Sep', p.period_to);
  end if;
  if v_ren <> date '2026-09-23' then
    fails := fails || format('K1 renewal_on=%s after payment — should be 23 Sep', v_ren);
  end if;
  if exists (select 1 from reminder_queue('genalpha') where member_name ilike 'Krishiv%') then
    fails := fails || 'K1 still in reminder_queue after paying'::text;
  end if;

  -- K2 · a second renewal chains again: 23 Sep -> 23 Oct, regardless of pay day.
  r := record_fee_payment('genalpha', v_enrol, 10000, 1, 'UPI', 'renewal', date '2026-10-05');
  select * into p from payments where id = (r->>'payment_id')::bigint;
  if (p.period_from, p.period_to) is distinct from (date '2026-09-23', date '2026-10-23') then
    fails := fails || format('K2 second renewal ran %s -> %s, expected 23 Sep -> 23 Oct', p.period_from, p.period_to);
  end if;

  if array_length(fails,1) > 0 then
    raise exception E'krishiv next-cycle test FAILED:\n  - %', array_to_string(fails, E'\n  - ');
  end if;
  raise notice 'krishiv next-cycle blocks passed (K1-K2)';
end $$;
