-- demo_snapshot(): make the revenue chart agree with the collections figure.
--
-- WHAT WAS WRONG
--
-- 2026-08-12za built the monthly series from tenant_revenue_streams(), on
-- the reasoning that a shared function is the one authority. Measured after
-- applying, the dashboard would have shown:
--
--     Revenue · August      ₹57k          <- tenant_revenue_streams
--     collected this month  ₹527,200      <- sum(payments)
--
-- Both on the same screen, differing by 9x. tenant_revenue_streams is a
-- COURT-VENUE function: its streams are tennis / pickleball / memberships,
-- i.e. booking income. It does not include coaching fee payments, which are
-- the demo academy's actual revenue and the thing we are selling.
--
-- A demo whose own two numbers disagree is worse than either number alone,
-- and it contradicts the pitch in the most visible way possible: the whole
-- claim is that a parent's message and the manager's screen can never quote
-- different amounts.
--
-- WHY THIS IS NOT A SECOND MONEY IMPLEMENTATION
--
-- The house rule protects fee RULES — what a given student owes. That stays
-- exactly where it was: resolve_fee() decides amounts and reminder_queue()
-- decides who is due, and dues_count/dues_amount still come from
-- reminder_queue(). Summing payments that have already been recorded is
-- aggregation, not a pricing rule, and it must come from the same table as
-- collected_month or the two cannot agree.
--
-- tenant_revenue_streams() is still returned, as `booking_streams`, renamed
-- so nobody mistakes court income for total collections again.
--
-- A SEED LIMITATION, NOT A BUG
--
-- All 227 demo payments sit in one month, so a six-month chart shows one
-- column and five zeros. That is the seed's shape, not a fault here —
-- demo_reset('rebuild') creates payments near today. Worth widening the
-- seed's payment history separately; faking a curve here would be inventing
-- revenue, which is the one thing a demo must not do.
--
-- Scope: shared. Demo tenant only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

create or replace function public.demo_snapshot()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  v_saved   text;
  v_streams jsonb;
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
  v_months_with_data int;
begin
  -- Narrowest identity that satisfies the shared guards, restored below.
  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","app_metadata":{"am_role":"staff","tenant_id":"demo"}}',
    true);

  -- Court/booking income, per sport. Kept for the fees screen; NOT the
  -- dashboard's revenue line.
  v_streams := tenant_revenue_streams('demo', 6);

  -- Dues: still the shared chain, unchanged. This is a fee RULE.
  select count(*), coalesce(sum(q.amount), 0)
    into v_dues_n, v_dues_amt
    from reminder_queue('demo', current_date) q;

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  -- Collections by month, from the same table as collected_month so the two
  -- figures on the dashboard agree. Six months back, zero-filled, in
  -- thousands for the chart.
  with months as (
    select date_trunc('month', current_date) - (n || ' months')::interval as mo
      from generate_series(5, 0, -1) n
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'm', to_char(m.mo, 'Mon'),
           'v', round(coalesce(p.total, 0) / 1000.0)
         ) order by m.mo), '[]'::jsonb)
    into v_months
    from months m
    left join (
      select date_trunc('month', created_at) as mo, sum(amount) as total
        from payments
       where tenant_id = 'demo'
       group by date_trunc('month', created_at)
    ) p on p.mo = m.mo;

  select count(*) into v_months_with_data
    from (select 1 from payments where tenant_id = 'demo'
           group by date_trunc('month', created_at)) q;

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

  select round(avg(case when ar.status = 'present' then 1.0 else 0.0 end), 3)
    into v_att_rate
    from attendance_records ar
    join sessions s on s.id = ar.session_id
   where ar.tenant_id = 'demo'
     and s.on_date > current_date - 30;

  return jsonb_build_object(
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
    -- so a reader can tell a thin chart from a broken one
    'revenue_months_with_data', v_months_with_data,
    'booking_streams',   v_streams
  );
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end $$;

comment on function public.demo_snapshot() is
  'Dashboard figures for the public demo, from Postgres. No arguments and '
  '''demo'' hard-coded. revenue_months comes from payments so it agrees with '
  'collected_month; dues come from reminder_queue so they agree with what a '
  'parent is told. booking_streams is court income only. Counts and amounts '
  'only — no names, no phone numbers. Anon-callable by design.';

revoke execute on function public.demo_snapshot() from public;
grant  execute on function public.demo_snapshot()
  to anon, authenticated, service_role;

do $$
declare s jsonb; v_aug numeric; v_coll numeric;
begin
  s := demo_snapshot();

  -- THE POINT OF THIS MIGRATION: the current month's chart column must
  -- match the collections figure, within rounding to thousands.
  v_coll := (s->>'collected_month')::numeric;
  select (e->>'v')::numeric into v_aug
    from jsonb_array_elements(s->'revenue_months') e
   where e->>'m' = to_char(current_date, 'Mon');

  if v_aug is null then
    raise exception 'the current month is missing from revenue_months';
  end if;
  if abs(v_aug - round(v_coll / 1000.0)) > 1 then
    raise exception
      'chart shows %k for this month but collected_month is % — the dashboard '
      'would contradict itself', v_aug, v_coll;
  end if;

  -- and the series must be six months, zero-filled, not just the months
  -- that happen to have payments
  if jsonb_array_length(s->'revenue_months') <> 6 then
    raise exception 'revenue_months has % entries, expected 6',
      jsonb_array_length(s->'revenue_months');
  end if;

  -- dues still from the chain
  if (s->>'dues_count')::int = 0 then
    raise exception 'dues_count is 0 — reminder_queue returned nothing';
  end if;

  -- still no PII
  if s::text ~* '"(name|phone|parent_name|member_name)"\s*:' then
    raise exception 'payload gained a personal-data key';
  end if;

  raise notice 'demo_snapshot: chart % k agrees with collections %; % month(s) have data',
    v_aug, v_coll, s->>'revenue_months_with_data';
end $$;
