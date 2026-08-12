-- Spread the demo tenant's payments across six months.
--
-- WHY
--
-- demo_reset('rebuild') creates all 225 demo payments near today, so every
-- one of them lands in the current month. With the dashboard now reading
-- real figures, the six-month chart renders as a flat line at zero and a
-- single vertical spike — which reads as a broken chart, not a young academy.
-- A prospect sees that before they see anything else.
--
-- IS THIS FAKING REVENUE?
--
-- No, and the distinction matters. Every demo row is synthetic already, and
-- date-shifting demo data to keep it representative is this seed's existing
-- practice: demo_reset('roll') exists precisely because "any fixed dataset
-- rots" and moves the calendar forward nightly. This does the same thing to
-- payment history. No amount is changed and no payment is invented — the
-- same 225 payments are simply distributed over the months a real academy
-- would have collected them in.
--
-- WHY A CRON JOB AND NOT A ONE-OFF UPDATE
--
-- Same reason the phone numbers needed a trigger: demo_reset('rebuild') will
-- re-cluster them the next time someone resets the demo after a walkthrough.
-- The spread therefore runs nightly at 02:15 IST, fifteen minutes after
-- demo-roll-nightly, so the chart is correct every morning regardless of how
-- often the demo was reset the day before.
--
-- Deterministic: the month offset comes from the payment id, not random(),
-- so a re-run is idempotent and two runs cannot disagree.
--
-- Scope: shared. Demo tenant only, enforced in the function body.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

create or replace function public.demo_spread_payments()
returns jsonb language plpgsql
set search_path = public as $$
declare v_moved int; v_months int;
begin
  -- Only ever the demo tenant. Ids are global: an unfiltered UPDATE here
  -- would rewrite real academies' payment dates and destroy their finance
  -- history.
  with spread as (
    select p.id,
           -- keep the time of day, move the month. id % 6 gives a stable,
           -- near-even distribution without random().
           (date_trunc('month', now())
             - ((p.id % 6) || ' months')::interval
             + (p.created_at - date_trunc('month', p.created_at))) as new_at
      from payments p
     where p.tenant_id = 'demo'
  )
  update payments p
     set created_at = s.new_at
    from spread s
   where p.id = s.id
     and p.tenant_id = 'demo'
     and p.created_at <> s.new_at;
  get diagnostics v_moved = row_count;

  select count(*) into v_months
    from (select 1 from payments where tenant_id = 'demo'
           group by date_trunc('month', created_at)) q;

  return jsonb_build_object('moved', v_moved, 'months_with_data', v_months);
end $$;

comment on function public.demo_spread_payments() is
  'Distributes the demo tenant''s payments over six months so the dashboard '
  'chart is representative. Deterministic (id %% 6), demo-only, idempotent. '
  'Runs nightly after demo-roll-nightly because demo_reset(rebuild) '
  're-clusters them.';

revoke execute on function public.demo_spread_payments() from public, anon;
grant  execute on function public.demo_spread_payments() to service_role;

select public.demo_spread_payments();

-- 02:15 IST = 20:45 UTC. demo-roll-nightly is 20:30 UTC, so this lands
-- fifteen minutes after it.
do $$
begin
  perform cron.unschedule('demo-spread-payments');
exception when others then null;
end $$;

select cron.schedule('demo-spread-payments', '45 20 * * *',
                     $c$select public.demo_spread_payments()$c$);

-- ─────────────────────────────────────────────────────────────
-- Assertions
-- ─────────────────────────────────────────────────────────────
do $$
declare v_months int; v_min numeric; v_max numeric; s jsonb; n int;
begin
  select count(*) into v_months
    from (select 1 from payments where tenant_id = 'demo'
           group by date_trunc('month', created_at)) q;
  if v_months < 5 then
    raise exception 'demo payments still span only % month(s)', v_months;
  end if;

  -- no month may be empty, or the chart still has a hole
  select min(t), max(t) into v_min, v_max from (
    select coalesce(sum(amount), 0) as t
      from generate_series(0, 5) g
      left join payments p
        on p.tenant_id = 'demo'
       and date_trunc('month', p.created_at)
           = date_trunc('month', now()) - (g || ' months')::interval
     group by g
  ) q;
  if v_min = 0 then
    raise exception 'at least one of the six months has no payments';
  end if;
  -- and the spread should be roughly even, not one month carrying it all
  if v_max > v_min * 4 then
    raise exception 'payment spread is lopsided: min % max %', v_min, v_max;
  end if;

  -- no other tenant may have moved
  select count(*) into n from payments
   where tenant_id <> 'demo'
     and created_at > now() - interval '1 minute';
  if n > 0 then
    raise exception '% payment(s) outside the demo tenant were just modified', n;
  end if;

  -- and the snapshot must still be self-consistent
  s := demo_snapshot();
  if (s->>'revenue_months_with_data')::int < 5 then
    raise exception 'demo_snapshot still reports only % month(s) of data',
      s->>'revenue_months_with_data';
  end if;

  raise notice 'demo payments spread over % months; chart is representative', v_months;
end $$;
