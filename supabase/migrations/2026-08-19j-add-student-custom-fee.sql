-- ============================================================
-- 2026-08-19j · add_student() can carry an agreed fee
-- scope: shared
--
-- WHY THE FORM HAD NO AMOUNT BOX, AND WHY THAT WAS ONLY HALF RIGHT
-- A fee is not a property of a student. resolve_fee() answers it from a
-- chain — enrolment override, then member rule, batch, centre+sport,
-- sport, centre, tenant default — so the ordinary student needs no amount
-- typed anywhere: they join the Morning batch and the Morning rule prices
-- them. Typing a number per student would put 130 copies of the same fee
-- in the database, and raising the batch fee later would then miss every
-- one of them. That reasoning holds and is why the box was left out.
--
-- What it misses is the student whose fee is genuinely their own: a
-- sibling discount, a scholarship, a rate agreed three years ago and never
-- moved. That is exactly what enrollments.custom_amount is for, and
-- resolve_fee() already honours it as the FIRST rung — `source: 'custom'`,
-- beating every rule. There was simply no way to set it while adding
-- someone, so an academy loading its roll had to add the student, find
-- them again, and edit.
--
-- So the box is optional and stays empty for almost everyone. Left blank,
-- the chain decides and keeps deciding. Filled in, that student is pinned
-- to that amount until somebody clears it.
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
  p_by          text    default null,
  p_custom_fee  numeric default null
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
  v_custom numeric;
begin
  perform assert_staff(p_tenant);

  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'A name is required.';
  end if;

  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  if v_phone is not null then
    if length(v_phone) < 10 then
      raise exception 'That mobile number is not 10 digits.';
    end if;
    v_phone := right(v_phone, 10);
  end if;

  /* A fee of zero is a real answer — a scholarship — so only a NEGATIVE
     one is nonsense. nullif on the empty string keeps "left blank" and
     "agreed at ₹0" apart, which the chain treats completely differently:
     blank defers to the batch, zero overrides it. */
  v_custom := p_custom_fee;
  if v_custom is not null and v_custom < 0 then
    raise exception 'A fee cannot be negative.';
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
                           plan_months, custom_amount, joined_on, renewal_on, status)
  values (p_tenant, v_mid, v_centre, p_batch,
          1, v_custom, v_joined, (ist_today() + interval '1 month')::date, 'active')
  returning id into v_eid;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, v_mid, v_eid, 'admission', 'Added to the roll',
          'Existing student entered by ' || coalesce(p_by, 'staff') ||
          case when v_custom is not null
               then ' · agreed fee ' || v_custom::text else '' end);

  /* Reported, never decided here — and now asked WITH the override, so the
     toast quotes what this student will actually be charged rather than
     what their batch charges everyone else. */
  v_fee := resolve_fee(p_tenant, v_mid, v_centre, 'cricket', p_batch, 1, v_custom);

  return jsonb_build_object('ok', true, 'duplicate', false,
                            'member_id', v_mid, 'enrollment_id', v_eid,
                            'no_phone', (v_phone is null),
                            'fee', v_fee);
end
$function$;

revoke execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text, numeric) from public, anon;
grant  execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text, numeric) to authenticated, service_role;

/* The nine-argument version would otherwise linger and stay callable, and
   a client on an older build would silently lose the fee it sent. */
drop function if exists public.add_student(text, text, text, bigint, text, date, date, bigint, text);

-- ------------------------------------------------------------
-- Prove it, and clean up.
-- ------------------------------------------------------------
do $$
declare r jsonb; v_err text; b bigint; ids bigint[] := '{}'; m bigint;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  select id into b from batches where tenant_id='ska' and code='MORNING';

  -- BLANK: the batch rule decides, and keeps deciding
  r := add_student('ska', 'ZZ Fee Blank', null, b);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) is not null then
    raise exception 'a blank fee was stored as an override';
  end if;
  if (r->'fee'->>'source') <> 'batch' then
    raise exception 'expected the batch rule, got %', r->'fee'->>'source';
  end if;

  -- AGREED: pinned to this student, beating the batch
  r := add_student('ska', 'ZZ Fee Agreed', null, b, null, null, null, null, 'probe', 1800);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) <> 1800 then
    raise exception 'the agreed fee was not stored';
  end if;
  if (r->'fee'->>'source') <> 'custom' or (r->'fee'->>'monthly')::numeric <> 1800 then
    raise exception 'resolve_fee did not honour the override: %', r->'fee';
  end if;

  -- ZERO is a scholarship, not "unset"
  r := add_student('ska', 'ZZ Fee Zero', null, b, null, null, null, null, 'probe', 0);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) <> 0 then
    raise exception 'zero was not stored';
  end if;

  -- negative is nonsense
  begin
    perform add_student('ska', 'ZZ Fee Neg', null, b, null, null, null, null, 'probe', -50);
    raise exception 'accepted a negative fee';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'A fee cannot be negative%' then raise; end if;
  end;

  delete from member_timeline where tenant_id='ska' and member_id = any(ids);
  delete from enrollments     where tenant_id='ska' and member_id = any(ids);
  delete from members         where tenant_id='ska' and id = any(ids);
  if exists (select 1 from members where tenant_id='ska' and name like 'ZZ Fee%') then
    raise exception 'probe members survived';
  end if;
end $$;
