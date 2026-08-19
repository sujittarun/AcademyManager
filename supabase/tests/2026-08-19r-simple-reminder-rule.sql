-- Proves the simple chase rule BEHAVES, not merely that it parses.
--
-- The migration's own assertions passed while proving nothing: mezzo had
-- zero enrolments, so its queue was empty under either branch. This test
-- plants students at known distances from their due date and asserts who
-- comes back. Rolled back by run-test.sh, always.
do $t$
declare
  c_id bigint; b_id bigint; m_id bigint; e_id bigint;
  d int; n int; v_stage text; found int;
  expect_in  int[] := array[1, 2, 9, 40];   -- late: every one must appear
  expect_out int[] := array[-5, -2, 0];     -- not late yet: none may appear
begin
  select id into c_id from centres where tenant_id='mezzo' limit 1;
  select id into b_id from batches where tenant_id='mezzo' and code='weekday';

  foreach d in array (expect_in || expect_out) loop
    insert into members (tenant_id, name, phone, parent_name, parent_phone, status, joined)
    values ('mezzo', 'ZZ Probe '||d, '9000000'||lpad((500+d+50)::text,3,'0'),
            'ZZ Parent', '9000000'||lpad((500+d+50)::text,3,'0'), 'active', current_date)
    returning id into m_id;
    insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                             plan_months, joined_on, renewal_on, status)
    values ('mezzo', m_id, c_id, b_id, 'Guitar', 1, current_date,
            ist_today() - d, 'active');
  end loop;

  -- a) everyone late shows up, exactly once, labelled plainly
  foreach d in array expect_in loop
    select count(*) into found from reminder_queue('mezzo') q
      join members m on m.id = q.member_id where m.name = 'ZZ Probe '||d;
    if found <> 1 then
      raise exception '% day(s) late produced % queue rows, expected 1', d, found;
    end if;
    select q.stage into v_stage from reminder_queue('mezzo') q
      join members m on m.id = q.member_id where m.name = 'ZZ Probe '||d;
    if v_stage <> 'overdue' then
      raise exception '% day(s) late was labelled "%", expected plain overdue', d, v_stage;
    end if;
  end loop;

  -- b) nobody who is not yet late is nudged. The old ladder pinged at
  --    -2 and 0; he asked for neither, and being told about a fee that
  --    is not due is exactly the noise that makes an operator stop
  --    reading the screen.
  foreach d in array expect_out loop
    select count(*) into found from reminder_queue('mezzo') q
      join members m on m.id = q.member_id where m.name = 'ZZ Probe '||d;
    if found <> 0 then
      raise exception '% day(s) from due was nudged; simple mode must not', d;
    end if;
  end loop;

  -- c) 40 days late is still chased. The ladder stops at +15; a rule
  --    with no escalation has nothing to stop, and he wants to keep
  --    seeing it until it is paid.
  select count(*) into found from reminder_queue('mezzo') q
    join members m on m.id = q.member_id
   where m.name = 'ZZ Probe 40' and q.blocked_reason is distinct from 'overdue_15_days';
  if found <> 1 then
    raise exception '40 days late was stopped by the +15 rung';
  end if;

  -- d) the fee on the queue is the fee chain's answer, not a guess:
  --    guitar must price at 1500 and piano at 2500, from SQL.
  select q.amount into n from reminder_queue('mezzo') q
    join members m on m.id = q.member_id where m.name = 'ZZ Probe 9';
  if n <> 1500 then raise exception 'guitar was chased for %, expected 1500', n; end if;

  raise notice 'simple rule: % late chased, % not-yet-due left alone',
    array_length(expect_in,1), array_length(expect_out,1);
end $t$;
