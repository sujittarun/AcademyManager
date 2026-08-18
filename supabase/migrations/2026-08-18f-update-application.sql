-- ============================================================
-- 2026-08-18f · update_application() — correct an application before it
--               becomes a member
-- scope: shared
--
-- WHY
-- Approving is a one-way door: approve_application() reads the row and
-- writes a member, an enrolment, a fee rule and a timeline entry from it.
-- Whatever the family typed is what the academy ends up holding — a
-- misspelt name, a digit missing from a phone, no batch chosen. Until now
-- the only options were to approve the mistake and repair the member
-- afterwards, or decline a family who had done nothing wrong.
--
-- There is also no UPDATE POLICY on applications (staff have SELECT
-- only), so this cannot be a PATCH from the client. Same reason
-- reject_application exists.
--
-- WHICH FIELDS, AND WHY EXACTLY THESE
-- Only the ones approve_application actually consumes:
--     name          -> members.name
--     phone         -> members.phone   (when there is no parent number)
--     parent_name   -> members.parent_name
--     parent_phone  -> members.phone and members.parent_phone
--     dob           -> members.dob
--     gender        -> members.gender
--     sport         -> members.program and the enrolment
--     centre_id     -> the enrolment. NOT NULL there, so a wrong one is
--                      not a cosmetic error — it aborts the approval
--     batch_id      -> the enrolment, and it is what resolve_fee() reads,
--                      so this is the field that decides what the family
--                      is charged
--
-- Editing anything else would be editing a record of what was submitted.
-- consent_accepted is deliberately NOT editable: it is a statement the
-- family made, not a field the academy owns. If consent needs changing,
-- the family needs to give it again.
--
-- IT REFUSES ONCE APPROVED. The member already exists and is its own
-- record from that moment; editing the application would leave the two
-- disagreeing with nothing to reconcile them. Fix the member instead.
-- ============================================================

create or replace function public.update_application(
  p_tenant       text,
  p_application  bigint,
  p_name         text    default null,
  p_phone        text    default null,
  p_parent_name  text    default null,
  p_parent_phone text    default null,
  p_dob          date    default null,
  p_gender       text    default null,
  p_sport        text    default null,
  p_centre       bigint  default null,
  p_batch        bigint  default null,
  p_by           text    default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare a applications; v_phone text; v_pphone text; v_age int;
begin
  perform assert_staff(p_tenant);

  select * into a from applications
   where id = p_application and tenant_id = p_tenant;
  if a.id is null then
    raise exception 'No such application.';
  end if;
  if a.member_id is not null or a.status = 'approved' then
    raise exception '% is already a member — edit the member, not the application.', a.name;
  end if;

  /* Every argument is OPTIONAL and null means "leave it alone", so the
     caller can send one field without having to resend the rest and
     accidentally blank something it never displayed. */
  /* LENGTH, not emptiness. right('123', 10) is '123' — non-null and
     perfectly happy — so checking only for null let a three-digit number
     through and stored it. Caught by this migration's own assertion,
     which is the argument for writing the assertion first. */
  v_phone  := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_pphone := regexp_replace(coalesce(p_parent_phone, ''), '\D', '', 'g');

  if p_phone is not null then
    if length(v_phone) < 10 then
      raise exception 'That mobile number is not 10 digits.';
    end if;
    v_phone := right(v_phone, 10);
  else
    v_phone := null;
  end if;

  if p_parent_phone is not null then
    if length(v_pphone) < 10 then
      raise exception 'That parent mobile number is not 10 digits.';
    end if;
    v_pphone := right(v_pphone, 10);
  else
    v_pphone := null;
  end if;

  if p_centre is not null and not exists (
       select 1 from centres where id = p_centre and tenant_id = p_tenant) then
    raise exception 'That centre does not belong to this academy.';
  end if;
  if p_batch is not null and not exists (
       select 1 from batches where id = p_batch and tenant_id = p_tenant) then
    raise exception 'That batch does not belong to this academy.';
  end if;

  /* Keep age in step with a corrected date of birth, or the row would say
     one thing and the date another. */
  v_age := case when p_dob is not null
                then extract(year from age(current_date, p_dob))::int
                else a.age end;

  update applications
     set name         = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
         phone        = coalesce(v_phone, phone),
         parent_name  = coalesce(nullif(trim(coalesce(p_parent_name, '')), ''), parent_name),
         parent_phone = coalesce(v_pphone, parent_phone),
         dob          = coalesce(p_dob, dob),
         age          = v_age,
         gender       = coalesce(nullif(trim(coalesce(p_gender, '')), ''), gender),
         sport        = coalesce(nullif(trim(coalesce(p_sport, '')), ''), sport),
         centre_id    = coalesce(p_centre, centre_id),
         batch_id     = coalesce(p_batch, batch_id),
         review_notes = case
                          when p_by is null then review_notes
                          else trim(both ' ' from
                               coalesce(review_notes || ' · ', '') ||
                               'edited by ' || p_by)
                        end
   where id = p_application and tenant_id = p_tenant;

  select * into a from applications where id = p_application;
  return jsonb_build_object('ok', true, 'id', a.id, 'name', a.name,
                            'batch_id', a.batch_id, 'centre_id', a.centre_id);
end
$function$;

revoke execute on function public.update_application(
  text, bigint, text, text, text, text, date, text, text, bigint, bigint, text) from public, anon;
grant  execute on function public.update_application(
  text, bigint, text, text, text, text, date, text, text, bigint, bigint, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and CLEAN UP — this block writes, and on a real apply the
-- transaction commits.
-- ------------------------------------------------------------
do $$
declare v_id bigint; r jsonb; a applications; v_centre bigint;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);

  select id into v_centre from centres where tenant_id = 'ska' and active limit 1;

  v_id := (submit_application(
            p_tenant => 'ska', p_name => 'ZZ Edit Probe',
            p_phone => '9000000981')->>'id')::bigint;

  -- A single field changes and nothing else is blanked.
  r := update_application('ska', v_id, p_name => 'ZZ Edited Name', p_by => 'probe');
  select * into a from applications where id = v_id;
  if a.name <> 'ZZ Edited Name' then raise exception 'name is %', a.name; end if;
  if a.phone <> '9000000981'    then raise exception 'phone was clobbered: %', a.phone; end if;

  -- A corrected date of birth drags the age with it.
  r := update_application('ska', v_id, p_dob => (current_date - interval '9 years')::date);
  select * into a from applications where id = v_id;
  if a.age <> 9 then raise exception 'age is %, expected 9', a.age; end if;

  -- A bad phone is refused rather than silently stored.
  begin
    perform update_application('ska', v_id, p_phone => '123');
    raise exception 'accepted a 3-digit phone';
  exception when others then
    if sqlerrm not like 'That mobile number%' then raise; end if;
  end;

  -- A centre from another academy is refused.
  begin
    perform update_application('ska', v_id, p_centre => 1);
    raise exception 'accepted a foreign centre';
  exception when others then
    if sqlerrm not like 'That centre does not%' then raise; end if;
  end;

  -- Once approved it must refuse.
  perform approve_application('ska', v_id, 'probe');
  begin
    perform update_application('ska', v_id, p_name => 'ZZ Too Late');
    raise exception 'edited an approved application';
  exception when others then
    if sqlerrm not like '%already a member%' then raise; end if;
  end;

  -- CLEAN UP everything the assertions created, children first.
  select * into a from applications where id = v_id;
  delete from member_timeline where tenant_id = 'ska' and member_id = a.member_id;
  delete from enrollments     where tenant_id = 'ska' and member_id = a.member_id;
  delete from applications    where tenant_id = 'ska' and id = v_id;
  delete from members         where tenant_id = 'ska' and id = a.member_id;

  if exists (select 1 from applications where id = v_id) then
    raise exception 'probe application survived';
  end if;
  if exists (select 1 from members where tenant_id = 'ska' and name like 'ZZ %') then
    raise exception 'probe member survived';
  end if;
end $$;
