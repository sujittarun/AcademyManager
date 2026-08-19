-- ============================================================
-- 2026-08-19h · add_student() — put an EXISTING student on the roll
-- scope: shared
--
-- WHY THIS EXISTS
-- Every route into `members` so far assumed a NEW enquiry: the admission
-- form writes an application and approve_application turns it into a
-- member. An academy arriving on the platform has 130 students who
-- enrolled years ago, and making the office invent an application for each
-- of them — with a consent statement nobody made today — is asking them to
-- file a fiction.
--
-- WHY IT IS A FUNCTION AND NOT TWO INSERTS FROM THE APP
-- A student is a member AND an enrolment. Written from the client that is
-- two round trips with no transaction: a failure between them leaves a
-- member on the roster who is in no batch, invisible to every register and
-- to the fee chase, and looking exactly like a healthy row. It also needs
-- centre_id (NOT NULL) and a renewal date the ladder can read, neither of
-- which a form should be inventing.
--
-- DUPLICATES ARE REFUSED, not silently doubled. Loading a roll by hand
-- means re-typing, interruptions and someone else starting the same list.
-- Same name AND same phone in the same academy is a double-entry, not a
-- sibling — siblings share a phone but not a name, and twins share neither
-- a name nor a birthday in practice. The existing member is returned so
-- the app can say "already on the roll" instead of creating a twin nobody
-- notices until the fees go out twice.
-- ============================================================

create or replace function public.add_student(
  p_tenant      text,
  p_name        text,
  p_phone       text,
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

  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'A name is required.';
  end if;

  /* Ten digits, last ten — the same rule submit_application uses, so a
     number pasted as +91 98765 43210 lands identically wherever it is
     typed. It is how a reminder reaches them, so it is not optional. */
  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(v_phone) < 10 then
    raise exception 'A 10-digit mobile number is required.';
  end if;
  v_phone := right(v_phone, 10);

  /* Already here? Hand back who, rather than making a second one. */
  select id into v_exist from members
   where tenant_id = p_tenant
     and lower(btrim(name)) = lower(btrim(p_name))
     and (phone = v_phone or parent_phone = v_phone)
     and status <> 'discontinued'
   limit 1;
  if v_exist is not null then
    return jsonb_build_object('ok', false, 'duplicate', true,
                              'member_id', v_exist,
                              'message', p_name || ' is already on the roll.');
  end if;

  /* One active centre is the common case and the form should not ask. A
     centre from another academy is refused rather than trusted. */
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

  /* A student who joined last year joined last year. The renewal is always
     measured from TODAY, though — the ladder chases the next payment, not
     a date that passed eleven months ago, and back-dating it would put the
     whole roll straight into "overdue" the moment it is loaded. */
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

  /* Reported, never decided here — the chain owns the amount. A student
     whose batch has no rule comes back 'unset', and the app must say so
     rather than print a zero. */
  v_fee := resolve_fee(p_tenant, v_mid, v_centre, 'cricket', p_batch, 1, null);

  return jsonb_build_object('ok', true, 'duplicate', false,
                            'member_id', v_mid, 'enrollment_id', v_eid,
                            'fee', v_fee);
end
$function$;

revoke execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text) from public, anon;
grant  execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and CLEAN UP — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare r jsonb; r2 jsonb; v_err text; v_mid bigint; v_batch bigint;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  select id into v_batch from batches where tenant_id='ska' and code='MORNING';

  -- a short phone is refused
  begin
    perform add_student('ska', 'ZZ Add Probe', '12345');
    raise exception 'accepted a 5-digit phone';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'A 10-digit%' then raise; end if;
  end;

  -- the good path makes BOTH rows
  r := add_student('ska', 'ZZ Add Probe', '+91 90000 00810', v_batch, 'ZZ Parent', null, null, null, 'probe');
  v_mid := (r->>'member_id')::bigint;
  if (r->>'ok')::boolean is not true then raise exception 'add failed: %', r; end if;
  if (select phone from members where id = v_mid) <> '9000000810' then
    raise exception 'phone not normalised: %', (select phone from members where id = v_mid);
  end if;
  if not exists (select 1 from enrollments where member_id = v_mid and batch_id = v_batch) then
    raise exception 'no enrolment, or the wrong batch';
  end if;
  if (select renewal_on from enrollments where member_id = v_mid) <= ist_today() then
    raise exception 'the new student is already overdue';
  end if;

  -- the same person again is refused, and says who they are
  r2 := add_student('ska', 'ZZ Add Probe', '9000000810', v_batch);
  if (r2->>'duplicate')::boolean is not true then
    raise exception 'a duplicate was created';
  end if;
  if (r2->>'member_id')::bigint <> v_mid then
    raise exception 'the duplicate pointed at the wrong member';
  end if;

  -- another academy's batch is refused
  begin
    perform add_student('ska', 'ZZ Add Probe 2', '9000000811', 1);
    raise exception 'accepted a foreign batch';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That batch does not%' then raise; end if;
  end;

  -- CLEAN UP, children first
  delete from member_timeline where tenant_id='ska' and member_id = v_mid;
  delete from enrollments     where tenant_id='ska' and member_id = v_mid;
  delete from members         where tenant_id='ska' and id = v_mid;
  if exists (select 1 from members where tenant_id='ska' and name like 'ZZ Add Probe%') then
    raise exception 'probe member survived';
  end if;
end $$;
