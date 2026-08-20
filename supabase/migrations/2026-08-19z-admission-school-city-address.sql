-- ============================================================
-- 2026-08-19z · the admission form can send school, city and address
-- scope: shared
--
-- SKA asked for these three as required fields. No schema change is
-- needed and none is made: applications already has school, city and
-- address columns, and members has school and address — they have been
-- there all along with nothing writing to them. This only opens the door
-- between the form and the columns.
--
-- Required-ness is the FORM's business, not this function's. A validation
-- rule belongs where the person is standing; putting it here as well would
-- mean two places to change when one academy wants city optional, and the
-- one in SQL would win silently. The function accepts what it is given and
-- refuses only what is nonsense.
--
-- Copied verbatim from the live definition with three arguments and three
-- insert columns added. Everything else — the tenant-scoped rate limit,
-- the Aadhaar check, the storage-path guards that stop one academy's row
-- pointing at another's file — is byte-for-byte what was there.
-- ============================================================

create or replace function public.submit_application(
  p_tenant text, p_name text, p_phone text,
  p_email text default null, p_level text default null, p_goal text default null,
  p_program text default null, p_slot text default null, p_trial date default null,
  p_dob date default null, p_age integer default null, p_gender text default null,
  p_parent_name text default null, p_parent_phone text default null,
  p_centre bigint default null, p_consent boolean default null,
  p_terms boolean default null, p_source text default null,
  p_photo_path text default null, p_aadhaar_path text default null, p_aadhaar text default null,
  p_school text default null, p_city text default null, p_address text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id      bigint;
  v_phone   text;
  v_pphone  text;
  v_centre  bigint;
  v_recent  int;
  v_aadhaar text;
begin
  if not tenant_exists(p_tenant) then
    raise exception 'Unknown academy.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A name is required.';
  end if;

  v_phone  := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_pphone := regexp_replace(coalesce(p_parent_phone, ''), '\D', '', 'g');
  if length(v_phone) < 10 and length(v_pphone) < 10 then
    raise exception 'A 10-digit mobile number is required.';
  end if;
  v_phone  := case when length(v_phone)  >= 10 then right(v_phone, 10)  else null end;
  v_pphone := case when length(v_pphone) >= 10 then right(v_pphone, 10) else null end;

  /* SCOPED TO THE TENANT. Before 2026-08-17d this counted every academy's
     applications together, so a busy academy throttled a quiet one's
     admissions. Keep the tenant_id in this predicate. */
  select count(*) into v_recent
    from applications
   where tenant_id = p_tenant
     and phone = coalesce(v_pphone, v_phone)
     and created_at > now() - interval '1 hour';
  if v_recent >= 5 then
    raise exception 'Too many applications from this number just now. Please try again later.';
  end if;

  select id into v_centre from centres
   where tenant_id = p_tenant and (p_centre is null or id = p_centre) and active
   order by (id = p_centre) desc, id limit 1;

  /* An Aadhaar number is 12 digits or it is not one. */
  v_aadhaar := nullif(regexp_replace(coalesce(p_aadhaar, ''), '\D', '', 'g'), '');
  if v_aadhaar is not null and v_aadhaar !~ '^[0-9]{12}$' then
    raise exception 'An Aadhaar number is 12 digits.';
  end if;

  /* THE PATHS MUST BELONG TO THIS ACADEMY. The caller is anonymous and
     chose these strings; without this a row could point at another
     tenant's object. Refused loudly — a silently dropped document is a
     family who thinks the academy has their photo. */
  if p_photo_path is not null and p_photo_path not like (p_tenant || '/%') then
    raise exception 'That photo does not belong to this academy.';
  end if;
  if p_aadhaar_path is not null and p_aadhaar_path not like (p_tenant || '/%') then
    raise exception 'That document does not belong to this academy.';
  end if;

  insert into applications (
    tenant_id, name, phone, email, level, goal, sport, slot, trial_date,
    dob, age, gender, parent_name, parent_phone, centre_id,
    consent_accepted, consent_accepted_at, terms_accepted, source_channel,
    student_photo_path, parent_aadhaar_path, parent_aadhaar,
    school, city, address, status)
  values (
    p_tenant, btrim(p_name), coalesce(v_pphone, v_phone), nullif(btrim(coalesce(p_email,'')),''),
    p_level, p_goal, p_program, p_slot, p_trial,
    p_dob, p_age, nullif(btrim(coalesce(p_gender,'')),''),
    nullif(btrim(coalesce(p_parent_name,'')),''), v_pphone, v_centre,
    p_consent, case when p_consent then now() else null end, p_terms,
    coalesce(nullif(btrim(coalesce(p_source,'')),''), 'website'),
    p_photo_path, p_aadhaar_path, v_aadhaar,
    nullif(btrim(coalesce(p_school,'')),''),
    nullif(btrim(coalesce(p_city,'')),''),
    nullif(btrim(coalesce(p_address,'')),''),
    'pending')
  returning id into v_id;

  /* Deliberately thin: an anonymous caller gets an acknowledgement, never
     the row back. */
  return jsonb_build_object('ok', true, 'id', v_id);
end
$function$;

/* This function is PUBLIC by design — an anonymous family fills the form —
   so the grants are restated rather than assumed, and rpc_audit() lists it
   among the four that are allowed to be anon-callable. */
grant execute on function public.submit_application(
  text, text, text, text, text, text, text, text, date, date, integer, text,
  text, text, bigint, boolean, boolean, text, text, text, text, text, text, text)
  to anon, authenticated, service_role;

/* The 21-argument version has to go: with both present every existing
   21-argument call matches both and fails as ambiguous. */
drop function if exists public.submit_application(
  text, text, text, text, text, text, text, text, date, date, integer, text,
  text, text, bigint, boolean, boolean, text, text, text, text);

-- ------------------------------------------------------------
-- Prove it, and clean up — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare r jsonb; v_id bigint; v_row applications; v_err text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  r := submit_application('ska', 'ZZ School Probe', '9000000801',
        null, null, null, null, null, null,
        null, 11, null, 'ZZ Parent', '9000000801', null, true, true, 'probe',
        null, null, null,
        'ZZ Vidya Mandir', 'Coimbatore', '12 ZZ Street, Vakaman');
  v_id := (r->>'id')::bigint;
  select * into v_row from applications where id = v_id;

  if v_row.school  <> 'ZZ Vidya Mandir'       then raise exception 'school not stored'; end if;
  if v_row.city    <> 'Coimbatore'            then raise exception 'city not stored'; end if;
  if v_row.address <> '12 ZZ Street, Vakaman' then raise exception 'address not stored'; end if;
  -- and nothing that already worked stopped working
  if v_row.consent_accepted is not true or v_row.consent_accepted_at is null then
    raise exception 'consent stopped being stored'; end if;
  if v_row.parent_name <> 'ZZ Parent' or v_row.age <> 11 then
    raise exception 'an existing field was dropped'; end if;
  if v_row.status <> 'pending' then raise exception 'status wrong'; end if;

  -- blank strings become NULL, not empty text the roster would print
  delete from applications where id = v_id;
  r := submit_application('ska', 'ZZ Blank Probe', '9000000802',
        null, null, null, null, null, null, null, 9, null, 'ZZ P', '9000000802',
        null, true, true, 'probe', null, null, null, '   ', '', null);
  v_id := (r->>'id')::bigint;
  select * into v_row from applications where id = v_id;
  if v_row.school is not null or v_row.city is not null or v_row.address is not null then
    raise exception 'whitespace was stored instead of null';
  end if;

  -- the guards that matter are untouched
  begin
    perform submit_application('ska', 'ZZ Foreign', '9000000803', null, null, null, null, null,
      null, null, null, null, null, '9000000803', null, true, true, 'probe',
      'leo/adm/x.jpg', null, null, null, null, null);
    raise exception 'accepted another academy''s photo path';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That photo does not%' then raise; end if;
  end;

  delete from applications where tenant_id='ska' and name like 'ZZ %';
  if exists (select 1 from applications where tenant_id='ska' and name like 'ZZ %') then
    raise exception 'probe applications survived';
  end if;
end $$;
