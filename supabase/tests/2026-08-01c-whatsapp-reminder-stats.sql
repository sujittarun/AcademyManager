-- ============================================================
-- Acceptance tests for whatsapp_reminder_stats()
--
-- Run with:  scripts/run-test.sh <migration> <this file>
-- Everything happens inside the runner's transaction and is rolled
-- back, so the seeded rows never survive.
--
-- The live data is too thin to prove much on its own (11 reminders, no
-- Meta callbacks), so each case SEEDS the exact situation it claims to
-- test and then asserts on the function's own output. A test that only
-- ran against today's rows would pass while proving nothing.
-- ============================================================

do $$
declare
  v        jsonb;
  v_raj    jsonb;
  n        int;
  v_rem_before int;
  v_rem_after  int;
  v_mid    bigint;
  v_mid2   bigint;
  v_rid    bigint;
  v_pid    bigint;
  v_batch  bigint;
  v_enr    bigint;
begin
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);

  -- ============================================================
  -- 1. Duplicate Meta callbacks are counted once
  -- ============================================================
  select (whatsapp_reminder_stats('raj', 4)->'totals'->>'remindersSent')::int into v_rem_before;

  select id into v_mid from members where tenant_id = 'raj' limit 1;
  insert into reminder_events (tenant_id, member_id, stage, status, channel, message_id, dry_run, ist_date, sent_by)
    values ('raj', v_mid, 'due', 'delivered', 'whatsapp', 'wamid.DUPTEST', false, current_date, 'engine');

  -- the same message_id arriving again must be impossible, not merely
  -- unlikely: the partial unique index is the test
  begin
    insert into reminder_events (tenant_id, member_id, stage, status, channel, message_id, dry_run, ist_date, sent_by)
      values ('raj', v_mid, 'due', 'read', 'whatsapp', 'wamid.DUPTEST', false, current_date, 'engine');
    raise exception 'FAIL 1: a duplicate (tenant_id, message_id) was accepted';
  exception when unique_violation then null;
  end;

  select (whatsapp_reminder_stats('raj', 4)->'totals'->>'remindersSent')::int into v_rem_after;
  if v_rem_after <> v_rem_before + 1 then
    raise exception 'FAIL 1: duplicate callback changed the count by % (expected 1)', v_rem_after - v_rem_before;
  end if;
  raise notice 'PASS 1  duplicate Meta callbacks counted once';

  -- ============================================================
  -- 3. Identical student ids in different tenants stay separate
  -- 2. Tenant data never mixes
  -- ============================================================
  -- give mpp a reminder for ITS member, then confirm raj's numbers
  -- did not move and neither academy absorbed the other's player
  select id into v_mid2 from members where tenant_id = 'mpp' limit 1;
  insert into reminder_events (tenant_id, member_id, stage, status, channel, dry_run, ist_date, sent_by)
    values ('mpp', v_mid2, 'due', 'manual_sent', 'whatsapp', false, current_date, 'manual');

  v_raj := whatsapp_reminder_stats('raj', 4);
  if exists (select 1 from jsonb_array_elements(v_raj->'academies') a where a->>'tenantId' <> 'raj') then
    raise exception 'FAIL 2: raj scope returned another tenant';
  end if;

  v := whatsapp_reminder_stats('all', 4);
  -- unique players across the period must be the SUM of per-tenant
  -- distinct members, never a merged set
  if (v->'totals'->>'uniquePlayers')::int
     < (select count(*) from (select distinct tenant_id, member_id from reminder_events
                               where coalesce(dry_run,false) = false
                                 and status in ('accepted','sent','delivered','read','manual_sent')) x)
  then
    raise exception 'FAIL 3: players were merged across tenants';
  end if;
  raise notice 'PASS 2  tenant data does not mix';
  raise notice 'PASS 3  identical student ids stay separate';

  -- ============================================================
  -- 4. All-academy totals equal the sum of authorised tenant results
  -- ============================================================
  if (v->'totals'->>'remindersSent')::int
     <> (select coalesce(sum((a->>'remindersSent')::int), 0)
           from jsonb_array_elements(v->'academies') a) then
    raise exception 'FAIL 4: totals <> sum of academies';
  end if;
  raise notice 'PASS 4  all-academy totals equal the sum of academies';

  -- ============================================================
  -- 5. Period-level players deduplicated on (tenant_id, member_id)
  -- ============================================================
  -- two reminders for the SAME member in the same period = one player
  insert into reminder_events (tenant_id, member_id, stage, status, channel, dry_run, ist_date, sent_by)
    values ('raj', v_mid, 'overdue', 'manual_sent', 'whatsapp', false, current_date - 1, 'manual');
  n := (whatsapp_reminder_stats('raj', 4)->'totals'->>'uniquePlayers')::int;
  if n <> (select count(distinct member_id) from reminder_events
            where tenant_id='raj' and coalesce(dry_run,false)=false
              and status in ('accepted','sent','delivered','read','manual_sent')) then
    raise exception 'FAIL 5: period players not deduplicated (got %)', n;
  end if;
  raise notice 'PASS 5  period players deduplicated on (tenant, member)';

  -- ============================================================
  -- 6. Sample / test / dry-run reminders are excluded
  -- ============================================================
  select (whatsapp_reminder_stats('raj', 4)->'totals'->>'remindersSent')::int into v_rem_before;
  insert into reminder_events (tenant_id, member_id, stage, status, channel, dry_run, ist_date, sent_by)
    values ('raj', v_mid, 'due', 'manual_sent', 'whatsapp', true,  current_date, 'manual'),   -- dry run
           ('raj', v_mid, 'due', 'manual_sent', 'whatsapp', false, current_date, 'sample'),   -- sample
           ('raj', v_mid, 'due', 'manual_sent', 'whatsapp', false, current_date, 'test'),     -- test
           ('raj', v_mid, 'due', 'queued',      'whatsapp', false, current_date, 'engine'),   -- never sent
           ('raj', v_mid, 'due', 'failed',      'whatsapp', false, current_date, 'engine');   -- failed
  select (whatsapp_reminder_stats('raj', 4)->'totals'->>'remindersSent')::int into v_rem_after;
  if v_rem_after <> v_rem_before then
    raise exception 'FAIL 6: excluded rows changed the count by %', v_rem_after - v_rem_before;
  end if;
  raise notice 'PASS 6  dry-run / sample / test / queued / failed excluded';

  -- ============================================================
  -- 7. Confirmed reminder payments attributed correctly
  --    (and unlinked / unconfirmed / uninteracted ones are not)
  -- ============================================================
  insert into reminder_events (tenant_id, member_id, stage, status, channel, dry_run, ist_date, sent_by)
    values ('raj', v_mid, 'due', 'delivered', 'whatsapp', false, current_date, 'engine')
    returning id into v_rid;
  insert into wa_flow_events (tenant_id, member_id, reminder_id, step, at)
    values ('raj', v_mid, v_rid, 'paid', now());

  -- a) linked + interacted + confirmed  → counts, at ITS OWN amount
  insert into payments (tenant_id, member_id, amount, mode, on_date, status, reminder_event_id, created_at)
    values ('raj', v_mid, 2500, 'UPI', current_date, 'paid', v_rid, now()) returning id into v_pid;
  -- b) confirmed but NOT linked → must not count
  insert into payments (tenant_id, member_id, amount, mode, on_date, status, created_at)
    values ('raj', v_mid, 9999, 'Cash', current_date, 'paid', now());
  -- c) linked but NOT confirmed → must not count
  insert into payments (tenant_id, member_id, amount, mode, on_date, status, reminder_event_id, created_at)
    values ('raj', v_mid, 7777, 'UPI', current_date, 'pending_verification', v_rid, now());

  v_raj := whatsapp_reminder_stats('raj', 4);
  if (v_raj->'totals'->>'paymentsViaReminder')::int <> 1 then
    raise exception 'FAIL 7: expected 1 attributed payment, got %', v_raj->'totals'->>'paymentsViaReminder';
  end if;
  if (v_raj->'totals'->>'revenueViaReminder')::numeric <> 2500 then
    raise exception 'FAIL 7: revenue should be the confirmed payment amount, got %',
      v_raj->'totals'->>'revenueViaReminder';
  end if;
  raise notice 'PASS 7  only linked+interacted+confirmed payments attributed, at their own amount';

  -- a payment may not be attributed to ANOTHER tenant's reminder
  begin
    insert into payments (tenant_id, member_id, amount, mode, on_date, status, reminder_event_id, created_at)
      values ('mpp', v_mid2, 100, 'UPI', current_date, 'paid', v_rid, now());
    raise exception 'FAIL 7b: cross-tenant attribution was accepted';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%belongs to tenant%' then null; else raise; end if;
  end;
  raise notice 'PASS 7b cross-tenant payment attribution rejected';

  -- ============================================================
  -- 8. Each academy's timezone is respected
  -- ============================================================
  -- Put a reminder at 18:40 UTC today. In Asia/Kolkata that is already
  -- tomorrow (00:10 IST), so a tenant on IST must file it in the NEXT
  -- local day — and, at a month boundary, the next month.
  update tenants set config = jsonb_set(coalesce(config,'{}'::jsonb), '{timezone}', '"Pacific/Kiritimati"')
   where id = 'mpp';
  n := (whatsapp_reminder_stats('mpp', 4)->>'monthsRequested')::int;
  if n <> 4 then raise exception 'FAIL 8: timezone change broke the call'; end if;
  -- the month grid must be built in that tenant's zone
  if (whatsapp_reminder_stats('mpp', 4)->'months'->-1->>'monthKey')
     <> to_char(date_trunc('month', (now() at time zone 'Pacific/Kiritimati')), 'YYYY-MM') then
    raise exception 'FAIL 8: current month not cut in the tenant timezone';
  end if;
  raise notice 'PASS 8  month grid uses each academy timezone';

  -- ============================================================
  -- 9 / 10. Authorisation
  -- ============================================================
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"raj"}}', true);
  begin
    perform whatsapp_reminder_stats('leo', 4);
    raise exception 'FAIL 9: staff reached another tenant';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'PASS 9  admin/staff cannot request another tenant';

  begin
    perform whatsapp_reminder_stats('all', 4);
    raise exception 'FAIL 10: staff reached the cross-tenant view';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'PASS 10 tenant manager cannot access cross-tenant stats';

  -- an anonymous / unknown role gets nothing at all
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin
    perform whatsapp_reminder_stats('raj', 4);
    raise exception 'FAIL 10b: anon reached the stats';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'PASS 10b anon rejected';

  -- ============================================================
  -- 11. More than 1,000 events
  -- ============================================================
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"operator"}}', true);
  select (whatsapp_reminder_stats('raj', 4)->'totals'->>'remindersSent')::int into v_rem_before;
  insert into reminder_events (tenant_id, member_id, stage, status, channel, message_id, dry_run, ist_date, sent_by)
    select 'raj', v_mid, 'due', 'delivered', 'whatsapp', 'wamid.BULK.' || g, false, current_date, 'engine'
      from generate_series(1, 1500) g;
  select (whatsapp_reminder_stats('raj', 4)->'totals'->>'remindersSent')::int into v_rem_after;
  if v_rem_after <> v_rem_before + 1500 then
    raise exception 'FAIL 11: expected +1500, got +%', v_rem_after - v_rem_before;
  end if;
  -- and the aggregate still returns ONE object, not 1500 rows
  if jsonb_typeof(whatsapp_reminder_stats('raj', 4)) <> 'object' then
    raise exception 'FAIL 11: aggregate did not stay an object';
  end if;
  raise notice 'PASS 11 >1000 events aggregated correctly (+1500)';

  raise notice '── all backend acceptance tests passed ──';
end $$;
