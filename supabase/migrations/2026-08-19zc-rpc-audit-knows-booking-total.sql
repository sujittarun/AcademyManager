-- ============================================================
-- 2026-08-19zc · rpc_audit knows about public_booking_total
-- scope: shared
--
-- 2026-08-19zb added an anon-callable function that reads `bookings`, and
-- rpc_audit() correctly reported it the moment it landed — the audit is
-- meant to stay empty, so a new entry is a question to answer rather than
-- a number to explain away.
--
-- The answer, on the record: it returns a total and a count, never a row.
-- It takes the phone recorded on the bookings and only counts rows that
-- match, so the ids being guessable buys nothing — a stranger with a
-- correct id and the wrong number gets zero, which was checked over HTTP
-- with the real public key before this file was written.
--
-- Copied verbatim from the live definition with one entry added to the
-- allow-list, in the same shape as 2026-08-19d's.
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_audit()
 RETURNS TABLE(fn text, args text, touches text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           'public.request_staff_access',   -- added 2026-08-19d, see header
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
           'public.demo_snapshot',
           -- Added 2026-08-20. Returns a SUM and a COUNT for bookings the
           -- caller already made — never a row, never a name, never a
           -- phone. It requires the phone that is ON those bookings, so a
           -- caller can only total their own; a guessed id with the wrong
           -- number totals zero. It exists because an anonymous customer
           -- who has just booked three nets should be able to see what
           -- they owe, and adding that up in the page is the one thing
           -- this platform does not do with money.
           'public.public_booking_total'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$function$;


do $$
declare v_left text;
begin
  select string_agg(fn, ', ') into v_left from rpc_audit();
  if v_left is not null then
    raise exception 'rpc_audit is not empty: %', v_left;
  end if;
end $$;
