-- ============================================================
-- 2026-08-05g · Give the demo a ladder worth demonstrating
-- scope: shared
--
-- Two defects in 2026-08-05f, both found by exercising the seeded tenant
-- rather than by reading it.
--
-- 1. THE ASSERTION THAT COULD NOT FAIL.
--      if (resolve_upi('demo')->>'upi_id') <> 'crescent-demo@demoupi'
--    resolve_upi() returns {vpa, name, source} — there is no 'upi_id' key,
--    so the left side was always NULL, and `NULL <> 'x'` is NULL, not true.
--    The check passed by being unable to fail. (The underlying value was
--    right all along: resolve_upi('demo')->>'vpa' is crescent-demo@demoupi.)
--    Restated below with the correct key AND `is distinct from`, which is
--    the form that survives a null.
--
-- 2. THE LADDER WAS A WALL.
--    renewal_on = current_date + ((id % 40) - 16) spread offsets evenly over
--    -16..+23. Only ONE offset lands on heads-up (+2) and one on due (0),
--    while fifteen land in the overdue band — so the queue came out
--    overdue=33, due=2, heads_up=2. That demonstrates a collections problem,
--    not a reminder ladder. A prospect should see the whole ladder working:
--    a heads-up cohort, a due-today cohort, a chase cohort, and — the most
--    persuasive one — a cohort past +15 where the platform STOPS chasing.
-- ============================================================

-- The designed distribution. Deterministic in the member id so a rebuild
-- and a roll agree, and so the same member keeps the same story between
-- demos.
create or replace function public.demo_ladder_offset(p_seq bigint)
returns int
language sql
immutable
as $$
  select case (p_seq % 20)
    when 0 then  2   when 1 then  2   when 2 then  2    -- heads-up (-2 rule)
    when 3 then  0   when 4 then  0                     -- due today
    when 5 then -5   when 6 then -6                     -- first chase (+5)
    when 7 then -8   when 8 then -11  when 9 then -13   -- daily chase (+7..14)
    when 10 then -17 when 11 then -22                   -- past +15: platform STOPS
    else 6 + ((p_seq % 23))::int                        -- comfortably ahead
  end
$$;
comment on function public.demo_ladder_offset(bigint) is
  'Demo-only: renewal_on offset from today, designed so reminder_queue shows every rung of the ladder including the +15 stop.';
revoke execute on function public.demo_ladder_offset(bigint) from public, anon;
grant execute on function public.demo_ladder_offset(bigint) to authenticated, service_role;

create or replace function public.demo_reset(p_mode text default 'rebuild')
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_centre_a bigint; v_centre_b bigint;
  v_bad bigint; v_ten bigint;
  v_n int; v_dow int; v_out jsonb;
  -- Plausible-but-invented names. Deliberately drawn from common Indian
  -- given/family names so the demo reads as a real Bengaluru academy,
  -- and combined mechanically so no row is a real person.
  v_first text[] := array['Aarav','Diya','Vihaan','Ananya','Arjun','Ishita','Kabir','Meera',
                          'Rohan','Saanvi','Aditya','Kavya','Nikhil','Riya','Siddharth','Tara',
                          'Yash','Zara','Manav','Pooja','Rahul','Sneha','Varun','Nisha',
                          'Karan','Anjali','Dev','Lakshmi','Rohit','Priya'];
  v_last  text[] := array['Rao','Nair','Iyer','Menon','Shetty','Kulkarni','Desai','Bhat',
                          'Reddy','Pillai','Hegde','Kamath','Prabhu','Naik','Salian'];
begin
  perform assert_staff_or_service('demo');

  if p_mode not in ('rebuild', 'roll') then
    raise exception 'demo_reset: mode must be rebuild or roll, got %', p_mode;
  end if;

  -- ========================================================
  -- TEARDOWN. Every statement carries tenant_id='demo'.
  -- Ids are global: a DELETE on a shared table without tenant_id in the
  -- WHERE empties every academy. FK-safe order, children first.
  -- ========================================================
  if p_mode = 'rebuild' then
    delete from attendance_records where tenant_id = 'demo';
    delete from sessions            where tenant_id = 'demo';
    delete from reminder_events     where tenant_id = 'demo';
    delete from payments            where tenant_id = 'demo';
    delete from enrollments         where tenant_id = 'demo';
    -- The two tables 0022 (the seed template everyone copies) forgets.
    -- Neither has a FK, so neither is caught by a dependency walk:
    -- `attendance` is what shared_fn_coverage() counts as invisible rows,
    -- and `reminders_log` is what operator_portfolio turns into msgs_30d
    -- and a fabricated messaging cost.
    delete from attendance          where tenant_id = 'demo';
    delete from reminders_log       where tenant_id = 'demo';
    -- player-progress cluster (gated on features.playerTracking)
    delete from skill_assessment_events    where tenant_id = 'demo';
    delete from skill_assessments          where tenant_id = 'demo';
    delete from player_level_history       where tenant_id = 'demo';
    delete from progress_notes             where tenant_id = 'demo';
    delete from player_goals               where tenant_id = 'demo';
    delete from player_training_constraints where tenant_id = 'demo';
    delete from development_reviews        where tenant_id = 'demo';
    delete from training_observations      where tenant_id = 'demo';
    delete from player_progress            where tenant_id = 'demo';
    delete from skill_catalog              where tenant_id = 'demo';
    delete from development_levels         where tenant_id = 'demo';
    delete from members             where tenant_id = 'demo';
    delete from fee_rules           where tenant_id = 'demo';
    delete from batches             where tenant_id = 'demo';
    delete from coaches             where tenant_id = 'demo';
    delete from centres             where tenant_id = 'demo';
    delete from sports              where tenant_id = 'demo';
    delete from bookings            where tenant_id = 'demo';
    delete from applications        where tenant_id = 'demo';
    delete from events              where tenant_id = 'demo';

    -- ======================================================
    -- SEED
    -- ======================================================
    insert into sports (tenant_id, code, name, icon, active, sort) values
      ('demo','badminton','Badminton','🏸',true,1),
      ('demo','tennis','Tennis','🎾',true,2);

    insert into centres (tenant_id, code, name, short_name, address, contact, active, sort)
    values ('demo','CEN','Crescent Central','Central','12 Lakeview Road, Indiranagar, Bengaluru 560038','+91 80 4000 0001',true,1)
    returning id into v_centre_a;
    insert into centres (tenant_id, code, name, short_name, address, contact, active, sort)
    values ('demo','CNO','Crescent North','North','44 Palm Avenue, Yelahanka, Bengaluru 560064','+91 80 4000 0002',true,2)
    returning id into v_centre_b;

    insert into coaches (tenant_id, name, phone, role, active) values
      ('demo','Coach Ramesh Rao',   '9000000101','head',   true),
      ('demo','Coach Latha Nair',   '9000000102','coach',  true),
      ('demo','Coach Imran Shaikh', '9000000103','coach',  true),
      ('demo','Coach Sunita Hegde', '9000000104','coach',  true),
      ('demo','Coach Vikram Menon', '9000000105','coach',  true);

    -- Batches. days is the ISO weekday array the roll uses to decide
    -- whether a session exists today.
    insert into batches (tenant_id, centre_id, code, name, sport, days, start_time, end_time, coach_id, capacity, active, sort)
    select 'demo', c.centre, c.code, c.name, c.sport, c.days, c.st, c.en,
           (select id from coaches where tenant_id='demo' order by id limit 1 offset c.coach_ix),
           c.cap, true, c.sort
    from (values
      (v_centre_a,'B-JR-M','Badminton Juniors (Morning)','badminton', array[1,3,5], time '06:30', time '08:00', 0, 16, 1),
      (v_centre_a,'B-JR-E','Badminton Juniors (Evening)','badminton', array[1,2,4], time '16:30', time '18:00', 1, 16, 2),
      (v_centre_a,'B-AD-E','Badminton Advanced',        'badminton', array[2,4,6], time '18:00', time '19:30', 0, 12, 3),
      (v_centre_a,'T-BEG', 'Tennis Beginners',          'tennis',    array[1,3,5], time '17:00', time '18:30', 2, 14, 4),
      (v_centre_b,'B-KID', 'Badminton Kids',            'badminton', array[2,4],   time '16:00', time '17:00', 3, 18, 5),
      (v_centre_b,'B-INT', 'Badminton Intermediate',    'badminton', array[1,3,5], time '18:30', time '20:00', 1, 14, 6),
      (v_centre_b,'T-ADV', 'Tennis Advanced',           'tennis',    array[2,4,6], time '06:30', time '08:00', 4, 10, 7),
      (v_centre_b,'T-WKD', 'Tennis Weekend Clinic',     'tennis',    array[6,7],   time '09:00', time '10:30', 2, 12, 8)
    ) as c(centre, code, name, sport, days, st, en, coach_ix, cap, sort);

    -- FEE RULES — deliberately at four different levels of the 7-level
    -- chain, so a demo of resolve_fee() actually shows the chain
    -- resolving rather than one flat number:
    --   tenant default < sport < centre+sport < batch < member override
    insert into fee_rules (tenant_id, label, monthly_amount, plan_amounts, admission_fee, active, effective_from)
      values ('demo','Academy default', 2000, '{"1":2000,"3":5700,"6":10800,"12":20400}'::jsonb, 1000, true, current_date - 365);
    insert into fee_rules (tenant_id, label, sport, monthly_amount, plan_amounts, active, effective_from)
      values ('demo','Tennis',  'tennis',    2800, '{"1":2800,"3":8000,"6":15100,"12":28600}'::jsonb, true, current_date - 365);
    insert into fee_rules (tenant_id, label, centre_id, sport, monthly_amount, active, effective_from)
      values ('demo','North · badminton', v_centre_b, 'badminton', 2200, true, current_date - 365);
    insert into fee_rules (tenant_id, label, batch_id, monthly_amount, plan_amounts, active, effective_from)
      select 'demo','Badminton Advanced', id, 3200, '{"1":3200,"3":9100,"6":17300,"12":32600}'::jsonb, true, current_date - 365
        from batches where tenant_id='demo' and code='B-AD-E';

    -- payout_rules_party_scope requires the party's own id, so a blanket
    -- 'coach' rule is rejected: one row per coach, plus a centre share.
    -- Without these, compute_payouts() has nothing to compute and the
    -- payouts screen is an empty state.
    insert into payout_rules (tenant_id, label, party, coach_id, basis, value, active, effective_from)
    select 'demo', 'Coach share · ' || c.name, 'coach', c.id, 'percent',
           case when c.role = 'head' then 40 else 32 end, true, current_date - 365
      from coaches c where c.tenant_id = 'demo';
    insert into payout_rules (tenant_id, label, party, centre_id, basis, value, active, effective_from)
    select 'demo', 'Centre share · ' || c.short_name, 'centre', c.id, 'percent', 15, true, current_date - 365
      from centres c where c.tenant_id = 'demo';

    -- PLAYER-PROGRESS FRAMEWORK. Seeded BEFORE members, because the
    -- initialize_member_progress trigger on shared members fires on
    -- insert and needs the levels to exist.
    insert into development_levels (tenant_id, framework_version, level, name, summary, target_days, colour, active)
    values ('demo',1,1,'Foundation','Grip, stance, and consistent contact',            90,'#94a3b8',true),
           ('demo',1,2,'Developing','Rally tolerance and basic shot selection',       120,'#38bdf8',true),
           ('demo',1,3,'Competent','Match play, movement patterns, serve variety',    180,'#34d399',true),
           ('demo',1,4,'Advanced','Tactical depth, pace control, tournament ready',   240,'#fbbf24',true),
           ('demo',1,5,'Elite','State-level competition and specialisation',          365,'#f472b6',true);

    insert into skill_catalog (tenant_id, framework_version, level, skill_id, name, category, display_order, required, active)
    select 'demo', 1, s.lvl, s.code, s.name, s.cat, s.sort, s.lvl <= 3, true
    from (values
      (1,'GRIP','Correct grip','technique',1),  (1,'STANCE','Ready stance','technique',2),
      (1,'SERVE-L','Low serve','technique',3),  (1,'FOOT-1','Split step','movement',4),
      (2,'CLEAR','Overhead clear','technique',5),(2,'DROP','Drop shot','technique',6),
      (2,'RALLY','10-shot rally','consistency',7),(2,'FOOT-2','Four-corner movement','movement',8),
      (3,'SMASH','Jump smash','technique',9),   (3,'NET','Net kill','technique',10),
      (3,'MATCH','Singles match play','tactical',11),(3,'DEFEND','Defensive lift','technique',12),
      (4,'DECEPT','Deception','tactical',13),   (4,'PACE','Pace variation','tactical',14),
      (4,'STAM','Three-game stamina','fitness',15),(4,'DOUBLES','Doubles rotation','tactical',16),
      (5,'TOURN','Tournament temperament','mental',17),(5,'SPEC','Specialist role','tactical',18)
    ) as s(lvl, code, name, cat, sort);

    -- MEMBERS. Mechanically combined names, sequential synthetic phones.
    -- is_demo = true on every row: the column already exists on members,
    -- so no shared-table change is needed to mark them.
    --
    -- PHONES are sequential from 9000000201. They are synthetic, and the
    -- demo cannot message them: config.whatsapp has no phoneNumberId, so
    -- the send path fails closed (2026-08-05). The client rebrand must
    -- also remove the outbound wa.me links, which bypass the send path.
    insert into members (tenant_id, name, phone, parent_name, parent_phone, program, joined, status, venue, is_demo, gender, dob)
    select 'demo',
           v_first[1 + (g % array_length(v_first,1))] || ' ' || v_last[1 + (g % array_length(v_last,1))],
           '90000' || lpad((200 + g)::text, 5, '0'),
           v_first[1 + ((g*7) % array_length(v_first,1))] || ' ' || v_last[1 + (g % array_length(v_last,1))],
           '90000' || lpad((400 + g)::text, 5, '0'),
           case when g % 3 = 0 then 'Tennis' else 'Badminton' end,
           current_date - (30 + (g * 11) % 700),
           'active',
           case when g % 2 = 0 then 'Central' else 'North' end,
           true,
           case when g % 2 = 0 then 'M' else 'F' end,
           current_date - ((8 + g % 12) * 365 + (g * 13) % 365)
      from generate_series(1, 94) g;

    -- ENROLLMENTS. renewal_on is spread across the reminder ladder on
    -- purpose, so reminder_queue('demo') returns a realistic mix of
    -- heads-up / due / chasing rather than all-or-nothing.
    insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, plan_months, joined_on, renewal_on, status)
    select 'demo', m.id,
           case when m.venue = 'Central' then v_centre_a else v_centre_b end,
           b.id, b.sport,
           case when m.id % 4 = 0 then 3 else 1 end,
           m.joined,
           -- ladder spread: DESIGNED, not modulo. The modulo version put
           -- 33 of 94 into overdue against 2 due and 2 heads-up, which
           -- demos as a wall rather than as a working ladder.
           current_date + demo_ladder_offset(m.id),
           'active'
      from members m
      join lateral (
        select id, sport from batches
         where tenant_id = 'demo'
           and centre_id = case when m.venue = 'Central' then v_centre_a else v_centre_b end
           and sport = lower(m.program)
         order by (m.id % 3), id limit 1
      ) b on true
     where m.tenant_id = 'demo';

    -- SESSIONS for the last 45 days, only on each batch's own weekdays.
    insert into sessions (tenant_id, batch_id, on_date, coach_id, status)
    select 'demo', b.id, d::date, b.coach_id, 'held'
      from batches b
      cross join generate_series(current_date - 45, current_date, interval '1 day') d
     where b.tenant_id = 'demo'
       and extract(isodow from d)::int = any(b.days)
    on conflict do nothing;

    -- ATTENDANCE at a believable ~82% present, with absences and a few
    -- late marks — a register that is 100% present reads as a fixture.
    -- attendance_records_status_check allows ONLY present/absent, so the
    -- texture goes in `reason` rather than a third status value.
    insert into attendance_records (tenant_id, session_id, enrollment_id, status, reason, marked_at)
    select 'demo', s.id, e.id,
           case when (e.id * 7 + s.id * 3) % 100 < 82 then 'present' else 'absent' end,
           case when (e.id * 7 + s.id * 3) % 100 >= 82
                then (array['illness','travel','exams','no reason given'])[1 + ((e.id + s.id) % 4)]
           end,
           s.on_date + time '19:00'
      from sessions s
      join enrollments e on e.tenant_id = 'demo' and e.batch_id = s.batch_id
     where s.tenant_id = 'demo'
    on conflict do nothing;

    -- PAYMENTS for the months already collected. Written directly rather
    -- than through record_fee_payment() ON PURPOSE: that function also
    -- rolls renewal_on forward and closes a reminder_events row, which
    -- would immediately undo the ladder spread above. The demo's LIVE
    -- payments — the ones a prospect takes on screen — must still go
    -- through record_fee_payment(); this is history, not a live write.
    insert into payments (tenant_id, member_id, enrollment_id, centre_id, sport, name, type, amount, mode, on_date, months, status)
    select 'demo', e.member_id, e.id, e.centre_id, e.sport, m.name, 'Fee',
           (resolve_fee('demo', e.member_id, e.centre_id, e.sport, e.batch_id, 1, null)->>'amount')::numeric,
           case when e.id % 3 = 0 then 'UPI' when e.id % 3 = 1 then 'Cash' else 'Card' end,
           current_date - (30 * gs) - (e.id % 5)::int,
           -- payments_status_valid: paid | pending_verification | void.
           -- A few sit unverified so the confirm_payment() flow has
           -- something to act on during a demo.
           1, case when e.id % 23 = 0 then 'pending_verification' else 'paid' end
      from enrollments e
      join members m on m.id = e.member_id
      cross join generate_series(1, 3) gs
     where e.tenant_id = 'demo' and e.id % 5 <> 0;   -- one in five has arrears

    -- COURT BOOKINGS across the last 21 days and the next 7, so the
    -- calendar is populated in both directions. Unique on
    -- (tenant, date, hour, court) for non-cancelled rows.
    insert into bookings (id, tenant_id, name, sport, court, date, hour, amount, status, source)
    select 'demo-' || to_char(d::date,'YYYYMMDD') || '-' || crt || '-' || hr,
           'demo',
           v_first[1 + ((extract(day from d)::int * hr) % array_length(v_first,1))] || ' ' ||
           v_last[1 + (hr % array_length(v_last,1))],
           sp.sport, crt, d::date, hr,
           case when hr >= 16 then sp.peak else sp.off end,
           case when (extract(day from d)::int + hr) % 17 = 0 then 'cancelled' else 'confirmed' end,
           case when (hr % 4) = 0 then 'Playo' when (hr % 4) = 1 then 'Hudle' else 'Website' end
      from generate_series(current_date - 21, current_date + 7, interval '1 day') d
      cross join (values ('badminton','B',400,300), ('tennis','T',500,380)) sp(sport, pfx, peak, off)
      cross join generate_series(6, 21) hr
      cross join lateral (select sp.pfx || (1 + ((extract(day from d)::int + hr) % case when sp.sport='badminton' then 6 else 4 end))::text as crt) c
     where (extract(day from d)::int * 3 + hr * 5) % 7 < 3   -- ~43% occupancy
    on conflict do nothing;
  end if;

  -- ========================================================
  -- ROLL — nightly. Keeps the demo permanently "today" without
  -- fabricating collections: deliberately no record_fee_payment() call,
  -- which would write a payment AND re-roll renewal_on every night.
  -- ========================================================
  v_dow := extract(isodow from current_date)::int;

  -- today's sessions
  insert into sessions (tenant_id, batch_id, on_date, coach_id, status)
  select 'demo', b.id, current_date, b.coach_id, 'held'
    from batches b where b.tenant_id = 'demo' and v_dow = any(b.days)
  on conflict do nothing;

  -- yesterday's register
  insert into attendance_records (tenant_id, session_id, enrollment_id, status, reason, marked_at)
  select 'demo', s.id, e.id,
         case when (e.id * 7 + s.id * 3) % 100 < 82 then 'present' else 'absent' end,
         case when (e.id * 7 + s.id * 3) % 100 >= 82
              then (array['illness','travel','exams','no reason given'])[1 + ((e.id + s.id) % 4)]
         end,
         s.on_date + time '19:00'
    from sessions s
    join enrollments e on e.tenant_id = 'demo' and e.batch_id = s.batch_id
   where s.tenant_id = 'demo' and s.on_date = current_date - 1
  on conflict do nothing;

  -- keep the ladder spread anchored to today rather than drifting into
  -- "everything is overdue" after a fortnight untouched
  update enrollments
     set renewal_on = current_date + demo_ladder_offset(member_id)
   where tenant_id = 'demo' and status = 'active';

  -- one more day of bookings at the far edge
  insert into bookings (id, tenant_id, name, sport, court, date, hour, amount, status, source)
  select 'demo-' || to_char((current_date + 7),'YYYYMMDD') || '-' || crt || '-' || hr,
         'demo',
         v_first[1 + ((extract(day from (current_date+7))::int * hr) % array_length(v_first,1))] || ' ' ||
         v_last[1 + (hr % array_length(v_last,1))],
         sp.sport, crt, current_date + 7, hr,
         case when hr >= 16 then sp.peak else sp.off end, 'confirmed',
         case when (hr % 4) = 0 then 'Playo' when (hr % 4) = 1 then 'Hudle' else 'Website' end
    from (values ('badminton','B',400,300), ('tennis','T',500,380)) sp(sport, pfx, peak, off)
    cross join generate_series(6, 21) hr
    cross join lateral (select sp.pfx || (1 + ((extract(day from (current_date+7))::int + hr) % case when sp.sport='badminton' then 6 else 4 end))::text as crt) c
   where (extract(day from (current_date+7))::int * 3 + hr * 5) % 7 < 3
  on conflict do nothing;

  -- never let the demo's own subscription badge flip to overdue
  update subscriptions
     set renews_on = (current_date + interval '3 months')::date
   where tenant_id = 'demo' and renews_on < current_date;

  select jsonb_build_object(
    'ok', true, 'mode', p_mode,
    'members',   (select count(*) from members     where tenant_id='demo'),
    'enrollments',(select count(*) from enrollments where tenant_id='demo'),
    'sessions',  (select count(*) from sessions    where tenant_id='demo'),
    'attendance',(select count(*) from attendance_records where tenant_id='demo'),
    'payments',  (select count(*) from payments    where tenant_id='demo'),
    'bookings',  (select count(*) from bookings    where tenant_id='demo'),
    'progress',  (select count(*) from player_progress where tenant_id='demo')
  ) into v_out;
  return v_out;
end $fn$;

-- Re-pin the existing enrollments onto the designed spread.
update enrollments
   set renewal_on = current_date + demo_ladder_offset(member_id)
 where tenant_id = 'demo' and status = 'active';

-- ------------------------------------------------------------
-- Checks — written so each CAN fail.
-- ------------------------------------------------------------
do $$
declare v_head int; v_due int; v_over int; v_upi text;
begin
  select count(*) filter (where stage = 'heads_up'),
         count(*) filter (where stage = 'due'),
         count(*) filter (where stage = 'overdue')
    into v_head, v_due, v_over
    from reminder_queue('demo');

  if v_head < 3 then raise exception 'heads-up cohort is %, expected at least 3', v_head; end if;
  if v_due  < 2 then raise exception 'due-today cohort is %, expected at least 2', v_due;  end if;
  if v_over < 3 then raise exception 'overdue cohort is %, expected at least 3', v_over;  end if;
  -- the wall this migration exists to remove
  if v_over > (v_head + v_due) * 4 then
    raise exception 'overdue (%) still dwarfs heads_up+due (%) — ladder is still a wall',
      v_over, v_head + v_due;
  end if;

  -- the +15 stop must actually be stopping somebody, or the most
  -- persuasive thing the platform does is invisible in the demo
  if not exists (select 1 from enrollments
                  where tenant_id = 'demo' and status = 'active'
                    and renewal_on < current_date - 15) then
    raise exception 'nobody is past the +15 stop — that rung cannot be demonstrated';
  end if;
  -- The stop does NOT remove the row: reminder_queue keeps it and sets
  -- blocked_reason='overdue_15_days', so a human can still act while
  -- automated sending is off. That is what "manual only" means, and it is
  -- the rung most worth showing a prospect. Assert the flag, not absence —
  -- the first version of this check asserted absence and failed against a
  -- correctly-behaving platform.
  if exists (select 1 from reminder_queue('demo')
              where days_since > 15
                and coalesce(blocked_reason,'') <> 'overdue_15_days') then
    raise exception 'a past-+15 row is not carrying blocked_reason=overdue_15_days — the stop is not engaged';
  end if;
  if not exists (select 1 from reminder_queue('demo') where blocked_reason = 'overdue_15_days') then
    raise exception 'no row is showing the +15 stop — that rung cannot be demonstrated';
  end if;

  -- restated correctly: right key, and a form that fails on null
  v_upi := resolve_upi('demo')->>'vpa';
  if v_upi is distinct from 'crescent-demo@demoupi' then
    raise exception 'demo collects to %, not its own account', coalesce(v_upi, '<null>');
  end if;

  raise notice 'ladder: % heads-up, % due, % overdue; collecting to %', v_head, v_due, v_over, v_upi;
end $$;
