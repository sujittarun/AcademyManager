-- ============================================================
-- 2026-08-19b · submit_application accepts the documents, and approval
--               carries them onto the member
-- scope: shared
--
-- The columns and the bucket landed in 2026-08-19a. This is the write
-- path: the public form hands over two object names and, optionally, an
-- Aadhaar number, and approve_application copies all three to the member
-- so the record follows the person rather than being stranded on the
-- enquiry that created them.
--
-- WHY THE PATHS ARE VALIDATED HERE AND NOT TRUSTED
-- The caller is anonymous. A path is a string it chose, so without a check
-- one academy's form could file a document under another academy's folder
-- — which is precisely the isolation the bucket policy exists to give.
-- The policy already stops the UPLOAD landing outside a real tenant, but
-- nothing stops a caller from *claiming* a path it never wrote to, so the
-- row would point at another tenant's object. One line each fixes it:
--
--     the path must start with p_tenant || '/'
--
-- Anything else is refused outright rather than quietly nulled, because a
-- family who uploaded a photo and got a silent success would never know
-- the academy has no photo.
--
-- ADDING ARGUMENTS TO submit_application MEANS DROP + CREATE.
-- Postgres treats a changed default list as a new signature, and the old
-- one would linger and still be callable. 2026-08-17d had to do the same
-- thing for the same reason. Every argument stays OPTIONAL, so the tenant
-- apps that do not send documents are unaffected and need no release.
-- ============================================================

drop function if exists public.submit_application(
  text, text, text, text, text, text, text, text, date, date, integer, text,
  text, text, bigint, boolean, boolean, text);

create function public.submit_application(
  p_tenant        text,
  p_name          text,
  p_phone         text,
  p_email         text    default null,
  p_level         text    default null,
  p_goal          text    default null,
  p_program       text    default null,
  p_slot          text    default null,
  p_trial         date    default null,
  p_dob           date    default null,
  p_age           integer default null,
  p_gender        text    default null,
  p_parent_name   text    default null,
  p_parent_phone  text    default null,
  p_centre        bigint  default null,
  p_consent       boolean default null,
  p_terms         boolean default null,
  p_source        text    default null,
  p_photo_path    text    default null,
  p_aadhaar_path  text    default null,
  p_aadhaar       text    default null
)
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
    student_photo_path, parent_aadhaar_path, parent_aadhaar, status)
  values (
    p_tenant, btrim(p_name), coalesce(v_pphone, v_phone), nullif(btrim(coalesce(p_email,'')),''),
    p_level, p_goal, p_program, p_slot, p_trial,
    p_dob, p_age, nullif(btrim(coalesce(p_gender,'')),''),
    nullif(btrim(coalesce(p_parent_name,'')),''), v_pphone, v_centre,
    p_consent, case when p_consent then now() else null end, p_terms,
    coalesce(nullif(btrim(coalesce(p_source,'')),''), 'website'),
    p_photo_path, p_aadhaar_path, v_aadhaar, 'pending')
  returning id into v_id;

  /* Deliberately thin: an anonymous caller gets an acknowledgement, never
     the row back. */
  return jsonb_build_object('ok', true, 'id', v_id);
end
$function$;

revoke execute on function public.submit_application(
  text, text, text, text, text, text, text, text, date, date, integer, text,
  text, text, bigint, boolean, boolean, text, text, text, text) from public;
grant execute on function public.submit_application(
  text, text, text, text, text, text, text, text, date, date, integer, text,
  text, text, bigint, boolean, boolean, text, text, text, text)
  to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- approval carries the documents onto the member
-- ------------------------------------------------------------
/* approve_application, taken verbatim from the live definition with THREE
   COLUMNS ADDED to its members INSERT and nothing else touched.

   Written from memory the first time, this had assert_staff instead of
   assert_staff_or_service, the wrong resolve_fee signature, and a
   member_timeline INSERT naming a `detail` column that does not exist.
   The dry run refused it. Copy the function you are extending; do not
   reconstruct it. */
create or replace function public.approve_application(p_tenant text, p_application bigint, p_by text default 'staff'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  a    applications;
  mid  bigint;
  eid  bigint;
  fee  jsonb;
begin
  perform assert_staff_or_service(p_tenant);
  select * into a from applications where id = p_application and tenant_id = p_tenant;
  if not found then raise exception 'application not found'; end if;
  if a.status = 'approved' then
    return jsonb_build_object('member_id', a.member_id, 'already', true);
  end if;

  insert into members (tenant_id, name, phone, parent_name, parent_phone, dob,
                       gender, school, program, joined, status,
                       -- ADDED 2026-08-19b: the record follows the person,
                       -- not the enquiry that created them.
                       student_photo_path, parent_aadhaar_path, parent_aadhaar)
  values (p_tenant, a.name, coalesce(a.parent_phone, a.phone), a.parent_name,
          coalesce(a.parent_phone, a.phone), a.dob, a.gender, a.school,
          a.sport, ist_today(), 'active',
          a.student_photo_path, a.parent_aadhaar_path, a.parent_aadhaar)
  returning id into mid;

  fee := resolve_fee(p_tenant, mid, a.centre_id, a.sport, a.batch_id, 1, null);

  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, admission_fee, joined_on, renewal_on, status)
  values (p_tenant, mid, a.centre_id, a.batch_id, a.sport, 1,
          coalesce((fee->>'admission_fee')::numeric, 0), ist_today(),
          (ist_today() + interval '1 month')::date, 'active')
  returning id into eid;

  update applications
     set status = 'approved', reviewed_at = now(), reviewed_by = p_by, member_id = mid
   where id = a.id;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, mid, eid, 'admission', 'Admission approved',
          'Enrolled at centre #' || a.centre_id || coalesce(' · ' || a.sport, ''));

  return jsonb_build_object('member_id', mid, 'enrollment_id', eid,
                            'fee', fee, 'already', false);
end $function$;

revoke execute on function public.approve_application(text, bigint, text) from public, anon;
grant  execute on function public.approve_application(text, bigint, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and CLEAN UP — this block writes, and a real apply commits.
-- ------------------------------------------------------------
do $$
declare v_id bigint; a applications; v_mem bigint; v_err text;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);

  -- a path belonging to another academy is refused, not silently dropped
  begin
    perform submit_application(p_tenant => 'ska', p_name => 'ZZ Doc Probe',
      p_phone => '9000000801', p_photo_path => 'leo/adm/x/photo.jpg');
    raise exception 'accepted another academy''s path';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That photo does not belong%' then raise; end if;
  end;

  -- a malformed Aadhaar is refused
  begin
    perform submit_application(p_tenant => 'ska', p_name => 'ZZ Doc Probe',
      p_phone => '9000000801', p_aadhaar => '1234');
    raise exception 'accepted a 4-digit Aadhaar';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'An Aadhaar number is 12 digits%' then raise; end if;
  end;

  -- the good path stores all three, and approval carries them across
  v_id := (submit_application(
            p_tenant => 'ska', p_name => 'ZZ Doc Probe', p_phone => '9000000801',
            p_photo_path   => 'ska/adm/probe/photo.jpg',
            p_aadhaar_path => 'ska/adm/probe/aadhaar.pdf',
            p_aadhaar      => '111122223333')->>'id')::bigint;

  select * into a from applications where id = v_id;
  if a.student_photo_path <> 'ska/adm/probe/photo.jpg' then
    raise exception 'photo path not stored: %', a.student_photo_path;
  end if;
  if a.parent_aadhaar <> '111122223333' then
    raise exception 'aadhaar not stored: %', a.parent_aadhaar;
  end if;

  v_mem := (approve_application('ska', v_id, 'probe')->>'member_id')::bigint;
  if (select student_photo_path from members where id = v_mem) is distinct from 'ska/adm/probe/photo.jpg' then
    raise exception 'approval did not carry the photo to the member';
  end if;
  if (select parent_aadhaar from members where id = v_mem) is distinct from '111122223333' then
    raise exception 'approval did not carry the Aadhaar to the member';
  end if;

  -- CLEAN UP, children first
  delete from member_timeline where tenant_id='ska' and member_id = v_mem;
  delete from enrollments     where tenant_id='ska' and member_id = v_mem;
  delete from applications    where tenant_id='ska' and id = v_id;
  delete from members         where tenant_id='ska' and id = v_mem;

  if exists (select 1 from members where tenant_id='ska' and name like 'ZZ Doc Probe%') then
    raise exception 'probe member survived';
  end if;
end $$;
