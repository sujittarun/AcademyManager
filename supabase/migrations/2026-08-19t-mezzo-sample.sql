-- ============================================================
-- 2026-08-19t · Six sample students, so he sees a working app first
-- scope: mezzo
--
-- He should be shown a register that already works before he types
-- anything into it. All six are marked is_demo = true, so the day he
-- goes live they come out in one delete:
--
--     delete from members where tenant_id='mezzo' and is_demo;
--
-- RENEWAL DATES ARE SPREAD ON PURPOSE. Seeding them all on the 1st
-- produces a valid dataset that shows an academy in total collapse —
-- six children all overdue at once. These sit either side of today so
-- the Dues tab has something real to show and something to leave alone.
--
-- NO REAL-LOOKING PHONE NUMBER. 9000000xxx is a reserved-looking test
-- range. A number that looks real and belongs to a stranger is how a
-- WhatsApp fee reminder reaches the wrong person — and the Dues tab
-- builds a wa.me link straight from this column.
-- ============================================================

do $$
declare
  c_id bigint; b_wk bigint; b_sa bigint; m_id bigint; i int := 0;
  r record;
begin
  select id into c_id from centres where tenant_id='mezzo' and code='thadagam';
  select id into b_wk from batches where tenant_id='mezzo' and code='weekday';
  select id into b_sa from batches where tenant_id='mezzo' and code='saturday';

  for r in
    select * from (values
      ('Aarav Kumar',    'Piano',    'weekday',  -3),   -- 3 days late
      ('Diya Menon',     'Violin',   'weekday',  -1),   -- 1 day late: the first nudge
      ('Ishaan Rao',     'Guitar',   'saturday',  6),   -- due next week
      ('Meera Nair',     'Keyboard', 'weekday',  12),
      ('Rohan Pillai',   'Drums',    'saturday', -9),   -- well overdue
      ('Saanvi Krishna', 'Vocals',   'weekday',  20)
    ) as v(nm, ins, bt, due_in)
  loop
    i := i + 1;
    insert into members (tenant_id, name, phone, parent_name, parent_phone,
                         status, joined, is_demo)
    values ('mezzo', r.nm, '90000005'||lpad(i::text,2,'0'),
            'Parent of '||split_part(r.nm,' ',1), '90000005'||lpad(i::text,2,'0'),
            'active', current_date - 60, true)
    returning id into m_id;

    insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                             plan_months, joined_on, renewal_on, status)
    values ('mezzo', m_id, c_id,
            case when r.bt = 'weekday' then b_wk else b_sa end,
            r.ins, 1, current_date - 60, ist_today() + r.due_in, 'active');
  end loop;
end $$;

-- A fortnight of attendance, so the month grid is not an empty sheet.
-- Weekday students on weekdays, Saturday students on Saturdays — an
-- attendance row on a day the batch does not run would be a lie the
-- register then shows him.
do $$
declare r record; d date; i int := 0;
begin
  for r in
    select e.id as eid, e.batch_id, b.days
      from enrollments e join batches b on b.id = e.batch_id
      join members m on m.id = e.member_id
     where e.tenant_id='mezzo' and m.is_demo
  loop
    d := ist_today() - 20;
    while d <= ist_today() loop
      if extract(isodow from d)::int = any (r.days) then
        i := i + 1;
        -- roughly one absence in six, so the grid shows both marks
        perform mark_attendance('mezzo', r.batch_id, d, r.eid,
                                case when i % 6 = 0 then 'absent' else 'present' end);
      end if;
      d := d + 1;
    end loop;
  end loop;
end $$;

do $chk$
declare n int; v numeric;
begin
  select count(*) into n from members where tenant_id='mezzo' and is_demo;
  if n <> 6 then raise exception '% sample students, expected 6', n; end if;

  -- the register must actually have marks in it
  select sum(present_days) into v from attendance_month('mezzo', ist_today()-20, ist_today());
  if coalesce(v,0) = 0 then raise exception 'the sample register is empty'; end if;

  -- the dues list must show the late ones and not the others
  select count(*) into n from reminder_queue('mezzo');
  if n <> 3 then raise exception '% students overdue, expected 3 (-1, -3, -9 days)', n; end if;

  -- and the piano student must be priced at 2500 by the chain, not by a seed
  select amount into v from reminder_queue('mezzo') q where q.sport = 'Piano';
  if v <> 2500 then raise exception 'the piano student is being chased for %, expected 2500', v; end if;

  -- nothing here may carry a phone number that could reach a real person
  select count(*) into n from members where tenant_id='mezzo' and is_demo
     and phone !~ '^90000005';
  if n > 0 then raise exception '% sample students have a real-looking phone number', n; end if;

  raise notice 'sample: 6 students, 3 overdue, register populated';
end $chk$;
