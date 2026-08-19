-- ============================================================
-- 2026-08-19i · add_student() asks for a NAME and nothing else
-- scope: shared
--
-- 2026-08-19h made a 10-digit phone compulsory, reasoning that it is how a
-- fee reminder reaches a family. True, and still the wrong call: the
-- schema requires only members.name, and an academy typing up a roll from
-- a paper register does not have every number to hand. A form that refuses
-- the row is a form that gets abandoned halfway, and the student ends up
-- in nobody's list at all — which is worse than a student with no number.
--
-- A member with no phone is already a state this platform handles:
-- reminder_queue() reports them with a blocked_reason and declines to
-- chase, and the roster shows "no number". Nothing breaks; they simply
-- cannot be reminded until somebody fills it in.
--
-- DUPLICATE DETECTION HAS TO CHANGE WITH IT. Name+phone was the test, and
-- with no phone there is nothing to pair a name against:
--   · phone given  -> same name AND same number is the same person
--   · no phone     -> same name among members who ALSO have no number.
--     Two "Arjun Kumar"s with different numbers are two boys; two with no
--     number at all, entered minutes apart, is somebody typing twice.
-- Either way the existing member comes back rather than a twin nobody
-- notices until the fees go out twice.
-- ============================================================

create or replace function public.add_student(
  p_tenant      text,
  p_name        text,
  p_phone       text    default null,
  p_batch       bigint  default null,
  p_parent_name text    default null,
  p_dob         date    default null,
  p_joined_on   date    default null,
  p_centre      bigint  default null,
  p_by          text    default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone  text;
  v_centre bigint;
  v_joined date;
  v_mid    bigint;
  v_eid    bigint;
  v_exist  bigint;
  v_fee    jsonb;
begin
  perform assert_staff(p_tenant);

  /* The one thing that is genuinely required — it is the only NOT NULL
     column on members that a person has to supply. */
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'A name is required.';
  end if;

  /* Optional now. If one IS given it must be a real ten digits — a
     half-typed number is worse than none: it looks reachable, the queue
     tries to chase it, and a stranger gets the WhatsApp. */
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  if v_phone is not null then
    if length(v_phone) < 10 then
      raise exception 'That mobile number is not 10 digits.';
    end if;
    v_phone := right(v_phone, 10);
  end if;

  if v_phone is not null then
    select id into v_exist from members
     where tenant_id = p_tenant
       and lower(btrim(name)) = lower(btrim(p_name))
       and (phone = v_phone or parent_phone = v_phone)
       and status <> 'discontinued'
     limit 1;
  else
    select id into v_exist from members
     where tenant_id = p_tenant
       and lower(btrim(name)) = lower(btrim(p_name))
       and phone is null and parent_phone is null
       and status <> 'discontinued'
     limit 1;
  end if;
  if v_exist is not null then
    return jsonb_build_object('ok', false, 'duplicate', true,
                              'member_id', v_exist,
                              'message', p_name || ' is already on the roll.');
  end if;

  if p_centre is not null then
    select id into v_centre from centres
     where id = p_centre and tenant_id = p_tenant and active;
    if v_centre is null then
      raise exception 'That centre does not belong to this academy.';
    end if;
  else
    select id into v_centre from centres
     where tenant_id = p_tenant and active order by id limit 1;
    if v_centre is null then
      raise exception 'This academy has no active centre yet.';
    end if;
  end if;

  if p_batch is not null and not exists (
       select 1 from batches where id = p_batch and tenant_id = p_tenant) then
    raise exception 'That batch does not belong to this academy.';
  end if;

  /* The renewal is measured from TODAY even when the joining date is old —
     back-dating it would drop a freshly loaded roll straight into
     "overdue" and start chasing everyone on day one. */
  v_joined := coalesce(p_joined_on, ist_today());
  if v_joined > ist_today() then
    raise exception 'A joining date cannot be in the future.';
  end if;

  insert into members (tenant_id, name, phone, parent_name, parent_phone,
                       dob, program, joined, status, added_by)
  values (p_tenant, btrim(p_name), v_phone,
          nullif(btrim(coalesce(p_parent_name, '')), ''), v_phone,
          p_dob, 'Cricket coaching', v_joined, 'active', p_by)
  returning id into v_mid;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id,
                           plan_months, joined_on, renewal_on, status)
  values (p_tenant, v_mid, v_centre, p_batch,
          1, v_joined, (ist_today() + interval '1 month')::date, 'active')
  returning id into v_eid;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, v_mid, v_eid, 'admission', 'Added to the roll',
          'Existing student entered by ' || coalesce(p_by, 'staff'));

  v_fee := resolve_fee(p_tenant, v_mid, v_centre, 'cricket', p_batch, 1, null);

  return jsonb_build_object('ok', true, 'duplicate', false,
                            'member_id', v_mid, 'enrollment_id', v_eid,
                            'no_phone', (v_phone is null),
                            'fee', v_fee);
end
$function$;

revoke execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text) from public, anon;
grant  execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it across EVERY shape the form can send, and clean up.
-- ------------------------------------------------------------
do $$
declare r jsonb; v_err text; b bigint; ids bigint[] := '{}';
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  select id into b from batches where tenant_id='ska' and code='MORNING';

  -- 1. NAME ONLY — the whole point of this migration
  r := add_student('ska', 'ZZ Only Name');
  if (r->>'ok')::boolean is not true then raise exception 'name-only refused: %', r; end if;
  if (r->>'no_phone')::boolean is not true then raise exception 'no_phone not reported'; end if;
  ids := ids || (r->>'member_id')::bigint;
  if (select phone from members where id = (r->>'member_id')::bigint) is not null then
    raise exception 'a phone appeared from nowhere';
  end if;
  -- and they still got an enrolment, or they are on no register at all
  if not exists (select 1 from enrollments where member_id = (r->>'member_id')::bigint) then
    raise exception 'name-only student has no enrolment';
  end if;

  -- 2. name + batch, no phone
  r := add_student('ska', 'ZZ Name Batch', null, b);
  if (r->>'ok')::boolean is not true then raise exception 'name+batch refused'; end if;
  ids := ids || (r->>'member_id')::bigint;
  if (select batch_id from enrollments where member_id = (r->>'member_id')::bigint) <> b then
    raise exception 'batch not applied';
  end if;

  -- 3. name + phone, normalised
  r := add_student('ska', 'ZZ Name Phone', '+91 90000 00850');
  ids := ids || (r->>'member_id')::bigint;
  if (select phone from members where id = (r->>'member_id')::bigint) <> '9000000850' then
    raise exception 'phone not normalised';
  end if;

  -- 4. a HALF-TYPED phone is still refused: it looks reachable and is not
  begin
    perform add_student('ska', 'ZZ Short Phone', '99515');
    raise exception 'accepted a 5-digit phone';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That mobile number%' then raise; end if;
  end;

  -- 5. no name is still refused
  begin
    perform add_student('ska', ' ');
    raise exception 'accepted a blank name';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'A name is required%' then raise; end if;
  end;

  -- 6. duplicate WITHOUT a phone is caught
  r := add_student('ska', 'ZZ Only Name');
  if (r->>'duplicate')::boolean is not true then
    raise exception 'a phoneless duplicate was created';
  end if;

  -- 7. same name, DIFFERENT phones = two real people, both allowed
  r := add_student('ska', 'ZZ Same Name', '9000000861');
  ids := ids || (r->>'member_id')::bigint;
  r := add_student('ska', 'ZZ Same Name', '9000000862');
  if (r->>'duplicate')::boolean is true then
    raise exception 'two siblings/namesakes were merged into one';
  end if;
  ids := ids || (r->>'member_id')::bigint;

  -- CLEAN UP, children first
  delete from member_timeline where tenant_id='ska' and member_id = any(ids);
  delete from enrollments     where tenant_id='ska' and member_id = any(ids);
  delete from members         where tenant_id='ska' and id = any(ids);
  if exists (select 1 from members where tenant_id='ska' and name like 'ZZ %') then
    raise exception 'probe members survived';
  end if;
end $$;
