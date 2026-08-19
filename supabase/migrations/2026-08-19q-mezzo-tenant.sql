-- ============================================================
-- 2026-08-19q · Mezzo School of Music — the platform's first paying client
-- scope: mezzo
--
-- Dr. R. Santhana Krishnan, Director & Tutor. One venue on Thadagam Road,
-- Coimbatore; ~95 enrolled, ~80 active; and he is the only user of the
-- app. That last fact shapes everything: there is no front desk, no
-- second operator to correct a mistake, and no appetite for a screen
-- that needs explaining.
--
-- WHICH TABLE, worked through before writing any of this.
--
--   instrument -> `sports`. One sentence describes both: the discipline
--     a student enrols in, which prices their fee and groups their
--     class. Not a new noun, just a different word for it — the mapping
--     from "sport" to "instrument" is the app's job, not the schema's.
--     The payoff is exact: resolve_fee()'s chain already has a sport
--     rung, so "Piano 2500, everything else 1500" is two fee_rules rows
--     and no arithmetic in any client.
--   student -> members.   class -> batches.   a day of it -> sessions.
--   present -> attendance_records.   spending -> expenses.
--
-- No new table, no new column, no module cluster. Everything specific to
-- Mezzo is in tenants.config.
--
-- BATCHES ARE THE TIME WINDOW, NOT THE INSTRUMENT. The obvious modelling
-- is one batch per instrument, and it is wrong twice over: it would need
-- sixteen of them to carry two different day patterns, and it would make
-- the teacher pick an instrument before he can mark a register. He
-- teaches all eight himself, one student at a time, across one room. So
-- there are two batches — the weekday window and the Saturday window —
-- and the instrument rides on the enrolment, where the fee chain reads
-- it anyway.
--
--   Mon-Fri  15:00-20:00 IST
--   Sat      10:00-20:00 IST
--
-- FLUTE IS SEEDED INACTIVE. It is struck through by hand on the business
-- card he handed over, which reads as withdrawn rather than as a
-- printing error. Seeded so the row exists with its history, `active =
-- false` so it is not offered. One flag flips it back if that reading is
-- wrong; ASK before assuming either way.
--
-- publicTimetable stays false and modules.booking stays false — a music
-- school has no courts to sell, and new tenants are private by default.
-- ============================================================

insert into tenants (id, name, kind, config) values (
  'mezzo',
  'Mezzo School of Music',
  'academy',
  jsonb_build_object(
    'brand',   'Mezzo School of Music',
    'tagline', 'Learn to Play · Play to Learn',
    'owner',   'Dr. R. Santhana Krishnan',
    'phone',   '9843330665',
    'city',    'Coimbatore',
    'sport',   'Music',
    'address', 'No.39, Sai Complex, Opp to Avila Convent, Thadagam Road, Velandipalayam, Coimbatore - 641025',
    'website', 'https://mezzoschoolofmusic.in',
    'colors',  jsonb_build_object('primary', '#4B3F72', 'ink', '#2A2340'),
    'hours',   jsonb_build_object('monFri', '15:00-20:00', 'sat', '10:00-20:00', 'sun', 'closed'),
    -- One operator, so every screen is his. No coach role, no front desk.
    'operators', 1,
    'modules',  jsonb_build_object('booking', false),
    'features', jsonb_build_object('publicTimetable', false),
    -- He asked for one nudge, the day after a fee is late, and nothing
    -- else. That is a per-tenant RULE, so it lives here and is read by
    -- the shared reminder_queue() — not reimplemented in his app.
    'reminders', jsonb_build_object('mode', 'simple', 'afterDays', 1)
  )
)
on conflict (id) do update set name = excluded.name, config = excluded.config;

-- ------------------------------------------------------------
-- The one venue
-- ------------------------------------------------------------
insert into centres (tenant_id, code, name, short_name, address, contact, active, sort)
values ('mezzo', 'thadagam', 'Mezzo School of Music', 'Thadagam Rd',
        'No.39, Sai Complex, Opp to Avila Convent, Thadagam Road, Velandipalayam, Coimbatore - 641025',
        '9843330665', true, 1)
on conflict do nothing;

-- ------------------------------------------------------------
-- The instruments, in the order they are printed on his card
-- ------------------------------------------------------------
insert into sports (tenant_id, code, name, icon, active, sort) values
  ('mezzo', 'piano',    'Piano',    'piano',        true,  1),
  ('mezzo', 'keyboard', 'Keyboard', 'piano',        true,  2),
  ('mezzo', 'guitar',   'Guitar',   'music_note',   true,  3),
  ('mezzo', 'violin',   'Violin',   'music_note',   true,  4),
  ('mezzo', 'ukulele',  'Ukulele',  'music_note',   true,  5),
  ('mezzo', 'drums',    'Drums',    'music_note',   true,  6),
  ('mezzo', 'vocals',   'Vocals',   'mic',          true,  7),
  ('mezzo', 'flute',    'Flute',    'music_note',   false, 8)   -- struck through on the card
on conflict do nothing;

-- ------------------------------------------------------------
-- The two time windows
-- ------------------------------------------------------------
insert into batches (tenant_id, centre_id, code, name, sport, days, start_time, end_time, active, sort)
select 'mezzo', c.id, b.code, b.name, null, b.days, b.st, b.et, true, b.sort
  from centres c,
       (values ('weekday',  'Weekdays · 3–8 pm', array[1,2,3,4,5], time '15:00', time '20:00', 1),
               ('saturday', 'Saturday · 10–8',   array[6],         time '10:00', time '20:00', 2)
       ) as b(code, name, days, st, et, sort)
 where c.tenant_id = 'mezzo' and c.code = 'thadagam'
on conflict do nothing;

-- ------------------------------------------------------------
-- The fee chain. Two rows is the whole price list.
--   sport = 'Piano'  -> 2500   (the 'sport' rung)
--   everything else  -> 1500   (the tenant-default rung, no keys set)
-- Nothing else needs to know these numbers — resolve_fee() answers, and
-- record_fee_payment() is the only way money is written.
-- ------------------------------------------------------------
insert into fee_rules (tenant_id, label, sport, monthly_amount, plan_amounts,
                       admission_fee, effective_from, active, note)
values
  ('mezzo', 'Piano · monthly',           'Piano', 2500, '{}'::jsonb, 0, current_date, true,
   'Piano is the only instrument priced differently. Handwritten on the card he handed over.'),
  ('mezzo', 'All instruments · monthly',  null,   1500, '{}'::jsonb, 0, current_date, true,
   'Tenant default: keyboard, guitar, violin, ukulele, drums, vocals.')
on conflict do nothing;

-- ------------------------------------------------------------
-- Checks — reads only, except the fee probe which cleans up after itself
-- ------------------------------------------------------------
do $chk$
declare v jsonb; n int; c_id bigint;
begin
  select id into c_id from centres where tenant_id='mezzo' and code='thadagam';
  if c_id is null then raise exception 'the centre was not created'; end if;

  select count(*) into n from sports where tenant_id='mezzo' and active;
  if n <> 7 then raise exception '% active instruments, expected 7 (flute is inactive)', n; end if;

  select count(*) into n from batches where tenant_id='mezzo' and active;
  if n <> 2 then raise exception '% batches, expected 2', n; end if;

  -- The fee chain must answer 2500 for piano and 1500 for anything else,
  -- from SQL, with no client involved. This is the house rule made a test.
  v := resolve_fee('mezzo', null, c_id, 'Piano', null, 1, null);
  if (v->>'monthly')::numeric <> 2500 then
    raise exception 'piano resolves to %, expected 2500 (%)', v->>'monthly', v::text;
  end if;
  v := resolve_fee('mezzo', null, c_id, 'Guitar', null, 1, null);
  if (v->>'monthly')::numeric <> 1500 then
    raise exception 'guitar resolves to %, expected 1500 (%)', v->>'monthly', v::text;
  end if;
  v := resolve_fee('mezzo', null, c_id, 'Vocals', null, 1, null);
  if (v->>'monthly')::numeric <> 1500 then
    raise exception 'vocals resolves to %, expected 1500', v->>'monthly';
  end if;

  -- The app cannot even report a crash until this row exists, so prove
  -- the events policy now rather than discovering it from a silent app.
  insert into events (tenant_id, name, page, session_id, props)
  values ('mezzo', 'page_view', 'probe', 'probe-mezzo-1', '{"ver":"probe"}'::jsonb);
  delete from events where tenant_id='mezzo' and session_id='probe-mezzo-1';

  raise notice 'mezzo: centre %, 7 instruments, 2 batches, piano 2500 / rest 1500', c_id;
end $chk$;
