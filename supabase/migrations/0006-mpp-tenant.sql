-- ============================================================
-- 0006 · Register Match Point Pride as a tenant
-- scope: mpp
--
-- Pride is also modelled as a venue inside the older `matchpoint`
-- tenant, but that project may be shelved and the Pride owner wants a
-- separate app, so it becomes its own tenant.
--
-- Nothing here moves money or members. It creates the row, and the row
-- is what everything else needs to exist first:
--
--   * events_public_w (0003) rejects an insert whose tenant_id is not in
--     `tenants`, so the app cannot report a single error until this runs;
--   * platform_health / operator_portfolio iterate tenants, so Pride is
--     invisible in the console until this runs;
--   * resolve_fee and friends key off tenant_id.
--
-- Values are the real ones already in `matchpoint`'s config (payee,
-- UPI, phone) plus the Pride venue's own details, not invented ones.
--
-- Deliberately NOT set:
--   modules.booking          — Pride is coaching; CourtSync is opt-in
--   features.publicTimetable — private by default, per 0003
--   features.playerTracking  — gates the members trigger; off until asked
-- ============================================================

insert into tenants (id, name, kind, config)
values (
  'mpp',
  'Match Point Pride Badminton Academy',
  'academy',
  jsonb_build_object(
    'city',    'Hyderabad',
    'brand',   'Match Point Pride',
    'tagline', 'Every player starts somewhere. Nobody stays there.',
    'sport',   'badminton',
    'courts',  jsonb_build_object('narsingi', 7),
    'venues',  jsonb_build_object(
      'narsingi', jsonb_build_object(
        'name',    'Match Point Pride',
        'area',    'Narsingi',
        'address', 'Alkapur Road 30, beside Sam Houston Intl School, Narsingi, Hyderabad',
        'hours',   '5 AM - 1 AM',
        'phone',   '+91 77320 77327',
        'courts',  7,
        'prefix',  'P'
      )
    ),
    'billing', jsonb_build_object(
      'payee',         'Match Point Badminton Academy',
      'upiIds',        jsonb_build_array('7732077327@ybl'),
      'upiWindowDays', 5
    ),
    -- the app is coaching-only for now; both of these are opt-in elsewhere
    'modules',  jsonb_build_object('booking', false),
    'features', jsonb_build_object('publicTimetable', false)
  )
)
on conflict (id) do nothing;

-- Fail loudly rather than leaving a half-registered tenant behind — this
-- is the shape 0004 taught us to check for.
do $$
begin
  if not exists (select 1 from tenants where id = 'mpp') then
    raise exception 'mpp tenant row missing after insert';
  end if;
  if public.tenant_publishes_timetable('mpp') then
    raise exception 'mpp must not publish a public timetable by default';
  end if;
  if coalesce((select (config #>> '{modules,booking}')::boolean
                 from tenants where id = 'mpp'), true) then
    raise exception 'mpp must not have the booking module enabled';
  end if;
end $$;
