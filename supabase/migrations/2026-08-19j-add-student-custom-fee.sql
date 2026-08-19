-- ============================================================
-- 2026-08-19j · add_student() can carry an agreed fee
-- scope: shared
--
-- WHY THE FORM HAD NO AMOUNT BOX, AND WHY THAT WAS ONLY HALF RIGHT
-- A fee is not a property of a student. resolve_fee() answers it from a
-- chain — enrolment override, member, batch, centre+sport, sport, centre,
-- tenant default — so the ordinary student needs no amount typed anywhere:
-- they join the Morning batch and the Morning rule prices them. Verified
-- on the live row today: member 1870 stores no amount at all and resolves
-- to {"monthly": 2500, "source": "batch", "rule_id": 571}. Typing a number
-- per student would put 130 copies of that 2500 in the database, and
-- raising the batch fee later would then miss every one of them.
--
-- What it misses is the student whose fee is genuinely their own: a
-- sibling discount, a scholarship, a rate agreed three years ago and never
-- moved. That is what enrollments.custom_amount is for, and resolve_fee()
-- already honours it as the FIRST rung — 'source: custom', beating every
-- rule. There was simply no way to set it while adding someone, so an
-- academy loading its roll had to add the student, find them again, edit.
--
-- TYPING THE BATCH'S OWN NUMBER IS AGREEMENT, NOT AN OVERRIDE.
-- The trap this opens is worse than the gap it closes: an office loading
-- 130 students types the fee it knows — 2500 — into every one. Each is now
-- pinned, and next April's rise reaches everybody EXCEPT the students
-- somebody took the trouble to confirm. So an amount equal to what the
-- chain already says is collapsed back to no-override, and the caller is
-- told which happened. Only a DIFFERENT number is a decision about this
-- student.
-- ============================================================

create or replace function public.add_student(
  p_tenant        text,
  p_name          text,
  p_phone         text    default null,
  p_batch         bigint  default null,
  p_parent_name   text    default null,
  p_dob           date    default null,
  p_joined_on     date    default null,
  p_centre        bigint  default null,
  p_by            text    default null,
  p_custom_amount numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone   text;
  v_centre  bigint;
  v_joined  date;
  v_mid     bigint;
  v_eid     bigint;
  v_exist   bigint;
  v_chain   jsonb;
  v_fee     jsonb;
  v_custom  numeric;
  v_matched boolean := false;
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

  /* Zero is a real answer — a scholarship — so only a NEGATIVE amount is
     nonsense. The client must send null, not 0, for "left blank": the two
     mean opposite things to the chain, blank deferring to the batch and
     zero overriding it. */
  v_custom := p_custom_amount;
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

  /* What the chain says on its own, asked with the SAME arguments the
     reminder ladder will use later — the enrolment stores no sport, so a
     sport passed here and not there would quote one number today and
     chase a different one next month. 19h passed 'cricket'; harmless while
     every rule has sport null, wrong the day one does not. */
  v_chain := resolve_fee(p_tenant, v_mid, v_centre, null, p_batch, 1, null);

  if v_custom is not null
     and (v_chain ->> 'monthly') is not null
     and (v_chain ->> 'monthly')::numeric = v_custom then
    v_custom  := null;
    v_matched := true;
  end if;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id,
                           plan_months, custom_amount, joined_on, renewal_on, status)
  values (p_tenant, v_mid, v_centre, p_batch,
          1, v_custom, v_joined, (ist_today() + interval '1 month')::date, 'active')
  returning id into v_eid;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, v_mid, v_eid, 'admission', 'Added to the roll',
          'Existing student entered by ' || coalesce(p_by, 'staff') ||
          case when v_custom is not null
               then ' · fee set for this student at ' || trim(to_char(v_custom, 'FM999999990.00'))
               else '' end);

  v_fee := case when v_custom is null then v_chain
                else resolve_fee(p_tenant, v_mid, v_centre, null, p_batch, 1, v_custom) end;

  return jsonb_build_object('ok', true, 'duplicate', false,
                            'member_id', v_mid, 'enrollment_id', v_eid,
                            'no_phone', (v_phone is null),
                            'custom', v_custom,
                            'matched_rule', v_matched,
                            'fee', v_fee);
end
$function$;

revoke execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text, numeric) from public, anon;
grant  execute on function public.add_student(text, text, text, bigint, text, date, date, bigint, text, numeric) to authenticated, service_role;

/* An added argument makes a NEW function rather than replacing the old
   one, so the nine-argument version would linger — and every existing
   nine-argument call would then match BOTH and fail as ambiguous. It has
   to go. PostgREST resolves by argument name, so a client still on the
   old build keeps working against the ten-argument one. */
drop function if exists public.add_student(text, text, text, bigint, text, date, date, bigint, text);

-- ------------------------------------------------------------
-- Prove it, and clean up — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare r jsonb; v_err text; b bigint; ids bigint[] := '{}'; m bigint;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  select id into b from batches where tenant_id='ska' and code='MORNING';
  if b is null then raise exception 'no MORNING batch to test against'; end if;

  -- 1. BLANK: the batch rule decides, and keeps deciding
  r := add_student('ska', 'ZZ Fee Blank', null, b);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) is not null then
    raise exception 'a blank fee was stored as an override';
  end if;
  if (r->'fee'->>'source') <> 'batch' or (r->'fee'->>'monthly')::numeric <> 2500 then
    raise exception 'expected the 2500 batch rule, got %', r->'fee';
  end if;

  -- 2. A DIFFERENT number is pinned to this student and beats the batch
  r := add_student('ska', 'ZZ Fee Agreed', null, b, null, null, null, null, 'probe', 1800);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) <> 1800 then
    raise exception 'the agreed fee was not stored';
  end if;
  if (r->'fee'->>'source') <> 'custom' or (r->'fee'->>'monthly')::numeric <> 1800 then
    raise exception 'resolve_fee did not honour the override: %', r->'fee';
  end if;
  if (r->>'matched_rule')::boolean is true then
    raise exception '1800 was wrongly called a match for 2500';
  end if;

  -- 3. THE BATCH'S OWN NUMBER is agreement, not an override — so the
  --    student still follows the batch when it changes
  r := add_student('ska', 'ZZ Fee Same', null, b, null, null, null, null, 'probe', 2500);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) is not null then
    raise exception 'typing the batch fee pinned the student to it';
  end if;
  if (r->>'matched_rule')::boolean is not true then
    raise exception 'the caller was not told it matched the rule';
  end if;
  if (r->'fee'->>'source') <> 'batch' then
    raise exception 'expected to follow the batch, got %', r->'fee'->>'source';
  end if;

  -- 4. ZERO is a scholarship, not "unset"
  r := add_student('ska', 'ZZ Fee Zero', null, b, null, null, null, null, 'probe', 0);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) <> 0 then
    raise exception 'zero was not stored';
  end if;
  if (r->'fee'->>'source') <> 'custom' or (r->'fee'->>'monthly')::numeric <> 0 then
    raise exception 'zero did not override the batch: %', r->'fee';
  end if;

  -- 5. an amount with NO batch and no rule to fall back on is still kept
  r := add_student('ska', 'ZZ Fee NoBatch', null, null, null, null, null, null, 'probe', 1234);
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (select custom_amount from enrollments where member_id = m) <> 1234 then
    raise exception 'a fee was lost when there was no rule to compare it to';
  end if;

  -- 6. negative is nonsense
  begin
    perform add_student('ska', 'ZZ Fee Neg', null, b, null, null, null, null, 'probe', -50);
    raise exception 'accepted a negative fee';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'A fee cannot be negative%' then raise; end if;
  end;

  -- 7. everything 19i proved still holds — name only, no phone, enrolled
  r := add_student('ska', 'ZZ Fee NameOnly');
  m := (r->>'member_id')::bigint; ids := ids || m;
  if (r->>'no_phone')::boolean is not true
     or not exists (select 1 from enrollments where member_id = m) then
    raise exception 'the name-only path regressed: %', r;
  end if;

  delete from member_timeline where tenant_id='ska' and member_id = any(ids);
  delete from enrollments     where tenant_id='ska' and member_id = any(ids);
  delete from members         where tenant_id='ska' and id = any(ids);
  if exists (select 1 from members where tenant_id='ska' and name like 'ZZ Fee%') then
    raise exception 'probe members survived';
  end if;
end $$;
