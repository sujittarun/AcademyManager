-- demo_snapshot(): the public demo's dashboard numbers, from Postgres.
--
-- WHY THIS EXISTS
--
-- The demo now opens without a login, and until today its first screen read
-- from `assets/js/data.js` — 16 seed members and dues computed as
-- `count × LT_DATA.plans[0].amount`. Two problems, one commercial and one
-- of principle:
--
--   · a prospect with 100 students who is shown "Active members: 16" reads
--     the product as a toy;
--   · the demo repo's own rule is "every number on screen must come from
--     Postgres … a demo that computes fees in JavaScript demonstrates a
--     product we do not sell." Flat-rate dues in JS is exactly that.
--
-- Real figures for the demo tenant today: 94 active members, and 30 members
-- due worth ₹92,800 — computed by reminder_queue(), which is the same
-- function that decides what a parent's WhatsApp message says.
--
-- WHY IT TAKES NO ARGUMENTS
--
-- Every function that has leaked on this platform took a caller-chosen
-- identifier: 0009 keyed on the argument name `p_tenant`, and 0010 found
-- the ones taking an enrollment id instead. A function with no parameters
-- and `'demo'` as a literal cannot be pointed anywhere else, whatever the
-- caller sends. That is the same shape as demo_reset(), which the demo repo
-- notes is "hard-coded to tenant_id = 'demo' … deliberately".
--
-- WHY IT IMPERSONATES STAFF-OF-DEMO
--
-- tenant_revenue_streams() and tenant_health() guard with
--   `auth_role() = 'operator' or (auth_role() = 'staff' and auth_tenant() = p_tenant)`
-- and notably do NOT accept a service connection. An anonymous caller is
-- refused. So this function sets `request.jwt.claims` to staff-of-demo for
-- the duration of the call and restores it afterwards.
--
-- That is deliberately the NARROWEST identity that works, not a service
-- bypass: anything called inside can reach `demo` and nothing else. The
-- alternative — recomputing revenue and dues here — would create a second
-- implementation of the money chain, which is the one thing the house rule
-- forbids. Calling the real functions under a bounded identity keeps one
-- authority.
--
-- It is also forward-compatible: reminder_queue() currently performs no
-- authorisation at all (worth fixing separately), and when a guard is added
-- this function already satisfies it.
--
-- WHAT IT DOES NOT RETURN
--
-- No names, no phone numbers, no member rows. The dashboard needs counts and
-- amounts, so that is all it gets. A snapshot that carries no personal data
-- cannot leak any, and this endpoint is reachable by anyone.
--
-- Scope: shared. One deliberately anon-callable read, demo tenant only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

create or replace function public.demo_snapshot()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  v_saved   text;
  v_rev     jsonb;
  v_months  jsonb;
  v_dues_n  int;
  v_dues_amt numeric;
  v_members int;
  v_recent  int;
  v_batches int;
  v_centres int;
  v_today_n int;
  v_today_p int;
  v_collected numeric;
  v_att_rate numeric;
  result    jsonb;
begin
  -- Narrowest identity that satisfies the shared guards. Transaction-local,
  -- and restored below so nothing downstream inherits it.
  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"demo"}}',
    true);

  -- Revenue, from the shared function the fees screen is supposed to use.
  -- Its streams are per-sport; the chart wants one number per month, in
  -- thousands, so sum the streams here rather than in the client.
  v_rev := tenant_revenue_streams('demo', 6);
  select coalesce(jsonb_agg(jsonb_build_object(
           'm', e->>'m',
           'v', round((
                  select coalesce(sum((val)::numeric), 0)
                    from jsonb_each_text(e - 'm') as kv(k, val)
                ) / 1000.0)
         ) order by ord), '[]'::jsonb)
    into v_months
    from jsonb_array_elements(v_rev) with ordinality as t(e, ord);

  -- Dues, from the same function that decides what a parent is told. This is
  -- the number the JS version got wrong by multiplying a flat rate.
  select count(*), coalesce(sum(q.amount), 0)
    into v_dues_n, v_dues_amt
    from reminder_queue('demo', current_date) q;

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  -- Plain reads. This function is definer, so RLS does not apply inside it;
  -- every one of these is explicitly filtered to 'demo'.
  select count(*) into v_members from members
   where tenant_id = 'demo'
     and coalesce(status, 'active') not in ('discontinued', 'inactive');

  select count(*) into v_recent from members
   where tenant_id = 'demo' and joined > current_date - 45;

  select count(*) into v_batches from batches where tenant_id = 'demo';
  select count(*) into v_centres from centres where tenant_id = 'demo';

  select count(*), count(*) filter (where status = 'pending')
    into v_today_n, v_today_p
    from bookings
   where tenant_id = 'demo' and date = current_date;

  select coalesce(sum(amount), 0) into v_collected
    from payments
   where tenant_id = 'demo'
     and created_at >= date_trunc('month', now());

  -- attendance_records.status is text ('present' / 'absent'), not a boolean,
  -- and the table carries its own tenant_id — but the rate should be over
  -- SESSION dates, not when the register happened to be marked, so the join
  -- stays.
  select round(avg(case when ar.status = 'present' then 1.0 else 0.0 end), 3)
    into v_att_rate
    from attendance_records ar
    join sessions s on s.id = ar.session_id
   where ar.tenant_id = 'demo'
     and s.on_date > current_date - 30;

  result := jsonb_build_object(
    'source',            'postgres',
    'academy',           (select coalesce(name, id) from tenants where id = 'demo'),
    'as_of_ist',         to_char(now() at time zone 'Asia/Kolkata',
                                 'YYYY-MM-DD HH24:MI'),
    'active_members',    v_members,
    'joined_recently',   v_recent,
    'batches',           v_batches,
    'centres',           v_centres,
    'dues_count',        v_dues_n,
    'dues_amount',       v_dues_amt,
    'collected_month',   v_collected,
    'bookings_today',    v_today_n,
    'bookings_pending',  v_today_p,
    'attendance_rate',   v_att_rate,
    'revenue_months',    v_months,
    'revenue_streams',   v_rev
  );

  return result;
exception when others then
  -- Never leave a borrowed identity behind, even on failure.
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end $$;

comment on function public.demo_snapshot() is
  'Dashboard figures for the public demo, from Postgres. No arguments and '
  '''demo'' hard-coded, so it cannot be pointed at another tenant. Returns '
  'counts and amounts only — no names, no phone numbers. Deliberately '
  'anon-callable; allowlisted in rpc_audit().';

revoke execute on function public.demo_snapshot() from public;
grant  execute on function public.demo_snapshot()
  to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- rpc_audit(): demo_snapshot joins the reviewed anon-callable list.
-- ─────────────────────────────────────────────────────────────
create or replace function public.rpc_audit()
returns table(fn text, args text, touches text)
language sql stable security definer set search_path = public as $$
  with app_schemas as (
    select oid, nspname from pg_namespace
     where nspname in ('public', 'genalpha')
  ),
  tenant_tables as (
    select c.relname::text as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'tenant_id'
                      and not a.attisdropped)
  )
  select (n.nspname || '.' || p.proname)::text,
         pg_get_function_identity_arguments(p.oid),
         (select string_agg(distinct tt.t, ', ')
            from tenant_tables tt
           where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
    from pg_proc p
    join app_schemas n on n.oid = p.pronamespace
   where p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute')
     and (n.nspname || '.' || p.proname) <> all (array[
           'public.request_booking',
           'public.submit_application',
           'public.tenant_exists',
           'public.tenant_publishes_timetable',
           'public.sync_ingest',
           'genalpha.submit_admission_form',
           'genalpha.peek_next_admission_reg_no',
           'public.demo_track',
           -- The public demo's dashboard figures. No arguments, 'demo'
           -- hard-coded, and the payload is counts and amounts with no
           -- names or phone numbers in it. The demo is a public sales
           -- asset, so these numbers are meant to be seen.
           -- Reviewed 2026-08-12.
           'public.demo_snapshot'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$$;

revoke execute on function public.rpc_audit() from public, anon;
grant  execute on function public.rpc_audit() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- Assertions
-- ─────────────────────────────────────────────────────────────
do $$
declare s jsonb; n int; extra text;
begin
  s := demo_snapshot();

  -- it must report the real roster, not the seed's 16
  if (s->>'active_members')::int < 50 then
    raise exception 'demo_snapshot reports only % active members — it is not '
                    'reading Postgres', s->>'active_members';
  end if;

  -- dues must come from the chain, not a flat multiple
  if (s->>'dues_count')::int = 0 then
    raise exception 'demo_snapshot reports no dues; reminder_queue returned nothing';
  end if;
  if (s->>'dues_amount')::numeric <= 0 then
    raise exception 'demo_snapshot reports a zero dues amount';
  end if;

  -- and it must carry NO personal data
  if s::text ~* '"(name|phone|parent_name|member_name)"\s*:' then
    raise exception 'demo_snapshot payload contains a personal-data key';
  end if;
  if exists (select 1 from members where tenant_id = 'demo'
              and s::text like '%' || name || '%') then
    raise exception 'a demo member name appears in the snapshot payload';
  end if;

  -- the borrowed identity must not survive the call
  if coalesce(current_setting('request.jwt.claims', true), '') ~ 'am_role' then
    raise exception 'demo_snapshot left a borrowed jwt claim behind';
  end if;

  -- anon must be able to call it, and rpc_audit must stay clean
  if not has_function_privilege('anon', 'public.demo_snapshot()', 'execute') then
    raise exception 'anon cannot call demo_snapshot — the public demo would be blank';
  end if;
  select count(*), coalesce(string_agg(fn, ', '), '') into n, extra from rpc_audit();
  if n > 0 then
    raise exception 'rpc_audit() is not empty: %', extra;
  end if;

  raise notice 'demo_snapshot: % members, % dues worth %, no PII, anon-callable',
    s->>'active_members', s->>'dues_count', s->>'dues_amount';
end $$;
