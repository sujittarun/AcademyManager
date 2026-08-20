-- ============================================================
-- 2026-08-19zi · stop the lockdown canary tripping over a comment
-- scope: shared
--
-- 2026-08-19zh added a comment inside rpc_audit()'s body that referred to
-- "the is_locked() lesson from 0011" — and lockdown_escape_audit() matches
-- `is_locked` followed by a paren anywhere in a function's source, so it
-- reported rpc_audit as having reintroduced the escape. It had not; it had
-- mentioned it.
--
-- The canary is right to be blunt. Its header already records this exact
-- blind spot for tenant_reach_audit, which quotes the 0011 outage the same
-- way and is excluded by name. Adding a second name to that list every time
-- somebody writes prose about the lockdown makes the check weaker each
-- time — so the comment loses its parentheses instead, and the audit keeps
-- matching the thing that actually matters: a call.
--
-- Identical to the live definition apart from that sentence.
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
           'public.public_booking_total',
           -- Added 2026-08-19ze. Writes paid_claim_at / paid_claim_ref and
           -- nothing else — it cannot touch paid_at, status or amount, so
           -- the worst a forged call can do is tell the desk to go and look
           -- at an account where there is no money. Phone-guarded the same
           -- way, and skipped entirely once a booking is collected.
           'public.claim_booking_payment',
           -- Added 2026-08-19zg. NAMED INSIDE A STORAGE POLICY, which is
           -- why it must be anon-executable: a policy predicate runs as the
           -- calling role, and a function anon cannot execute makes the
           -- policy deny every upload rather than fail loudly. That is the
           -- lesson migration 0011 taught with the lockdown helper, in a
           -- different bucket. It
           -- answers one boolean — is this booking real, unpaid and mine —
           -- about an id the caller already holds, and returns nothing
           -- else.
           'public.booking_open_for_proof'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$function$;


do $$
begin
  if exists (select 1 from lockdown_escape_audit()) then
    raise exception 'lockdown_escape_audit still reports: %',
      (select string_agg(kind || ' ' || object, ', ') from lockdown_escape_audit());
  end if;
  if exists (select 1 from rpc_audit()) then
    raise exception 'rpc_audit is not empty: %', (select string_agg(fn, ', ') from rpc_audit());
  end if;
end $$;
