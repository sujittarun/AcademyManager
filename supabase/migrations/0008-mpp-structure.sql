-- ============================================================
-- 0008 · Pride's centre and sport
-- scope: mpp
--
-- The structure every other table hangs off: enrollments need a
-- centre_id, resolve_fee ranks rules by centre and sport, and
-- reminder_queue joins centres for the message.
--
-- Deliberately ONLY the centre and the sport. Batches, fee rules,
-- members and payments are the owner's live data — they are on his
-- phone in localStorage, not knowable from here, and inventing them
-- would put fictional students in a real database. They arrive through
-- a one-shot import from the app's own backup, which is the only source
-- that has them.
-- ============================================================

insert into centres (tenant_id, code, name, short_name, address, contact, active, sort)
values (
  'mpp', 'narsingi',
  'Match Point Pride',
  'Pride',
  'Alkapur Road 30, beside Sam Houston Intl School, Narsingi, Hyderabad',
  '+91 77320 77327',
  true, 1
)
on conflict do nothing;

insert into sports (tenant_id, code, name, icon, active, sort)
values ('mpp', 'badminton', 'Badminton', 'shuttle', true, 1)
on conflict do nothing;

do $$
declare v_centre bigint;
begin
  select id into v_centre from centres where tenant_id='mpp' and code='narsingi';
  if v_centre is null then
    raise exception 'mpp centre missing after insert';
  end if;
  if not exists (select 1 from sports where tenant_id='mpp' and code='badminton') then
    raise exception 'mpp sport missing after insert';
  end if;

  -- 0003 made anonymous timetable read opt-in. Pride has not opted in,
  -- so these rows must not be visible to anon. Assert the shape rather
  -- than trusting it, since this is the first tenant to add rows to
  -- these tables since that change.
  if public.tenant_publishes_timetable('mpp') then
    raise exception 'mpp centre/sport rows would be publicly readable';
  end if;
end $$;
