-- ============================================================
-- 2026-08-19d · rpc_audit() learns about request_staff_access
-- scope: shared
--
-- rpc_audit() lists SECURITY DEFINER functions anon may execute that touch
-- tenant data, and it is alarmed on hourly. It must stay EMPTY, or it
-- becomes a red light nobody looks at — the exact failure that makes a
-- real leak invisible.
--
-- request_staff_access is the fifth function public BY DESIGN: a coach
-- asking an academy for a login has no account yet, so anon is the only
-- role it can be called as. It writes one request row, returns {ok:true}
-- and nothing else, and is rate limited per tenant AND per address.
--
-- Adding a name here is a decision, not paperwork. The bar is: could an
-- anonymous caller learn or change something that is not theirs?
--
-- TAKEN VERBATIM from the live definition with ONE line added. Rewritten
-- from memory it had the wrong OUT parameters and Postgres refused it —
-- the same mistake approve_application caught earlier today. Copy the
-- function you are extending.
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
           'public.demo_snapshot'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$function$
;

do $do$
declare v_n int;
begin
  select count(*) into v_n from rpc_audit();
  if v_n <> 0 then
    raise exception 'rpc_audit is not empty (% rows) — something else became anon-callable', v_n;
  end if;
end $do$;
