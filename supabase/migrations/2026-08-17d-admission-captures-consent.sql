-- ============================================================
-- 2026-08-17d · submit_application: record a child, a parent, and consent
-- scope: shared
--
-- Three defects in one function, all of which bite the first tenant to
-- take real admissions through it (Super Kings, live 2026-09-01).
--
-- ------------------------------------------------------------
-- 1. CONSENT IS COLLECTED AND THROWN AWAY
-- ------------------------------------------------------------
-- The applications table has consent_accepted, terms_accepted and
-- consent_accepted_at. submit_application() accepts NONE of them, so
-- every admission form on this platform renders a consent checkbox,
-- validates it, and then discards it. The demo's form does exactly that
-- at admission.html:101 → :214.
--
-- Migration 2026-08-10q already wrote the problem down in plain words:
-- the platform "takes registrations for MINORS across six academies and
-- has never had anywhere to record that a parent agreed to anything."
-- The columns were added then. Nothing was ever wired to them.
--
-- consent_accepted_at is written HERE, as now(), server-side. A consent
-- timestamp supplied by a client is not evidence of anything.
--
-- ------------------------------------------------------------
-- 2. NO CHILD, NO PARENT
-- ------------------------------------------------------------
-- The function takes name/phone/email and four coaching-shaped strings
-- (level, goal, program, slot). It cannot record a date of birth, an
-- age, a parent's name or a parent's number — which is most of what an
-- academy admitting minors actually needs, and precisely what Super
-- Kings asked for. Those columns exist on the table; only the door was
-- missing.
--
-- ------------------------------------------------------------
-- 3. THE RATE LIMIT IS NOT TENANT-SCOPED  ← the one that would have hurt
-- ------------------------------------------------------------
-- The cap reads:
--     select count(*) from applications
--      where phone = v_phone and created_at > now() - interval '1 day'
-- with NO tenant_id predicate. It is therefore a counter shared across
-- all six academies: a parent who lodged three enquiries at Leo this
-- morning is refused by Super Kings this afternoon, and told
-- "we already have your enquiry" by an academy they have never contacted.
--
-- One academy's traffic silently throttling another's admissions is
-- exactly the cross-tenant coupling this platform exists to prevent.
-- Scoped to the tenant here.
--
-- ------------------------------------------------------------
-- WHY DROP AND RECREATE RATHER THAN CREATE OR REPLACE
-- ------------------------------------------------------------
-- CREATE OR REPLACE with a different parameter list creates a SECOND
-- OVERLOAD rather than replacing the function. The existing callers then
-- fail with "function submit_application(...) is not unique" — and the
-- existing callers are two live client apps:
--     LeoTennis/assets/js/cloud.js:175
--     AcademyManagerDemo/assets/js/cloud.js:195
-- Both send named arguments over PostgREST. Dropping the old signature
-- and creating one widened function whose NEW parameters all carry
-- DEFAULTS means those two calls resolve unchanged.
--
-- GRANTS ARE RESTORED EXPLICITLY. A drop takes the ACL with it, and this
-- is one of exactly four functions that are anon-executable BY DESIGN
-- (request_booking, submit_application, tenant_exists,
-- tenant_publishes_timetable). Forget the re-grant and every public
-- admission form on the platform returns "permission denied" — the same
-- shape of outage as revoking is_locked() from PUBLIC, which took Raj's
-- timetable down for six minutes.
-- ============================================================

drop function if exists public.submit_application(text, text, text, text, text, text, text, text, date);

create function public.submit_application(
  p_tenant  text,
  p_name    text,
  p_phone   text,
  p_email   text    default null,
  p_level   text    default null,
  p_goal    text    default null,
  p_program text    default null,
  p_slot    text    default null,
  p_trial   date    default null,
  -- new, all defaulted so the two existing callers are untouched
  p_dob           date   default null,
  p_age           int    default null,
  p_gender        text   default null,
  p_parent_name   text   default null,
  p_parent_phone  text   default null,
  p_centre        bigint default null,
  p_consent       boolean default null,
  p_terms         boolean default null,
  p_source        text   default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone   text;
  v_pphone  text;
  v_recent  int;
  v_age     int;
  v_centre  bigint;
  v_id      bigint;
begin
  if (select 1 from tenants where id = p_tenant) is null then
    raise exception 'unknown academy';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'name required';
  end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(v_phone) < 10 then
    raise exception 'valid phone required';
  end if;
  v_phone := right(v_phone, 10);

  v_pphone := nullif(right(regexp_replace(coalesce(p_parent_phone, ''), '\D', '', 'g'), 10), '');

  -- Cap: one phone, three enquiries a day, PER ACADEMY. The missing
  -- tenant_id predicate is the fix — see the header.
  select count(*) into v_recent
    from applications
   where tenant_id = p_tenant
     and phone = v_phone
     and created_at > now() - interval '1 day';
  if v_recent >= 3 then
    raise exception 'too many requests — we already have your enquiry';
  end if;

  -- Age: prefer a real date of birth, fall back to what was typed.
  -- Stored as well as derived, because a DOB keeps being true and an age
  -- stops being true on the child's next birthday.
  v_age := case
             when p_dob is not null then extract(year from age(current_date, p_dob))::int
             else p_age
           end;
  if v_age is not null and (v_age < 2 or v_age > 100) then
    raise exception 'check the age or date of birth';
  end if;

  -- Centre: if the academy has exactly one, use it rather than leaving
  -- the row unattributed. enrollments.centre_id is NOT NULL, so an
  -- application with no centre cannot later be approved — the member row
  -- is inserted first and the approval then aborts on the constraint,
  -- leaving a member with no enrolment.
  v_centre := p_centre;
  if v_centre is null then
    select id into v_centre
      from centres
     where tenant_id = p_tenant and active
     limit 2;                                   -- limit 2: see below
    if (select count(*) from centres where tenant_id = p_tenant and active) <> 1 then
      v_centre := null;                          -- more than one, do not guess
    end if;
  end if;

  insert into applications (
    tenant_id, name, phone, email, level, goal, program, slot, trial_date,
    dob, age, gender, parent_name, parent_phone, centre_id,
    consent_accepted, terms_accepted, consent_accepted_at, source_channel
  ) values (
    p_tenant, trim(p_name), v_phone,
    nullif(trim(coalesce(p_email, '')), ''),
    p_level, p_goal, p_program, p_slot, p_trial,
    p_dob, v_age, nullif(trim(coalesce(p_gender, '')), ''),
    nullif(trim(coalesce(p_parent_name, '')), ''), v_pphone, v_centre,
    p_consent, p_terms,
    -- server clock, always
    case when coalesce(p_consent, false) or coalesce(p_terms, false) then now() end,
    nullif(trim(coalesce(p_source, '')), '')
  )
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end
$function$;

-- ------------------------------------------------------------
-- Grants. Public by design — see the header. Restored explicitly
-- because the drop above took the old ACL with it.
-- ------------------------------------------------------------
grant execute on function public.submit_application(
  text, text, text, text, text, text, text, text, date,
  date, int, text, text, text, bigint, boolean, boolean, text
) to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, in the transaction that made it.
-- ------------------------------------------------------------
do $$
declare r jsonb; a applications; v_centre bigint;
begin
  -- 1. The old 9-argument call shape must still work — Leo and the demo
  --    both send exactly this and cannot be force-updated together.
  r := submit_application('ska', 'ZZ Legacy Shape', '9000000901', null, null, null, null, null, null);
  if not (r->>'ok')::boolean then raise exception 'legacy call shape broke'; end if;

  -- 2. The new fields land, and consent is stamped server-side.
  r := submit_application(
        p_tenant => 'ska', p_name => 'ZZ Test Child', p_phone => '9000000902',
        -- ::date matters — `current_date - interval` is a TIMESTAMP, and
        -- an unlabelled timestamp does not match the date parameter, so
        -- the whole overload fails to resolve.
        p_dob => (current_date - interval '11 years')::date,
        p_parent_name => 'ZZ Test Parent', p_parent_phone => '9000000903',
        p_consent => true, p_terms => true, p_source => 'website');
  select * into a from applications where id = (r->>'id')::bigint;

  if a.parent_name is null      then raise exception 'parent_name was not stored'; end if;
  if a.parent_phone <> '9000000903' then raise exception 'parent_phone is %', a.parent_phone; end if;
  if a.dob is null              then raise exception 'dob was not stored'; end if;
  if a.age <> 11                then raise exception 'age derived as %, expected 11', a.age; end if;
  if a.consent_accepted is not true then raise exception 'consent was not recorded'; end if;
  if a.consent_accepted_at is null  then raise exception 'consent timestamp missing'; end if;

  -- 3. A single-centre tenant gets its centre attributed, so the row can
  --    later be approved at all.
  select id into v_centre from centres where tenant_id = 'ska' and active;
  if a.centre_id is distinct from v_centre then
    raise exception 'centre_id is %, expected %', a.centre_id, v_centre;
  end if;

  -- 4. THE CROSS-TENANT REGRESSION. Three enquiries at one academy must
  --    not block a fourth at a DIFFERENT academy from the same phone.
  -- The cap is `>= 3`, so it refuses the FOURTH. Three must succeed.
  perform submit_application('ska', 'ZZ Cap One',   '9000000904');
  perform submit_application('ska', 'ZZ Cap Two',   '9000000904');
  perform submit_application('ska', 'ZZ Cap Three', '9000000904');
  begin
    perform submit_application('ska', 'ZZ Cap Four', '9000000904');
    raise exception 'the per-tenant cap did not fire';
  exception when others then
    if sqlerrm not like 'too many requests%' then raise; end if;
  end;
  -- capped at ska, but demo must still accept them
  r := submit_application('demo', 'ZZ Other Academy', '9000000904');
  if not (r->>'ok')::boolean then
    raise exception 'one academy''s cap is still blocking another''s admissions';
  end if;

  raise notice 'submit_application assertions passed';
end $$;
