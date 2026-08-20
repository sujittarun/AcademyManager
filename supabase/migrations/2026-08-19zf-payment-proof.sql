-- ============================================================
-- 2026-08-19zf · a screenshot beats a typed reference
-- scope: shared
--
-- Asking a customer to read a twelve-digit UTR off their UPI app and type
-- it into a form is a task most people abandon, and a mistyped one is
-- worse than none — the desk searches for a number that was never real.
-- Everyone already knows how to send a screenshot.
--
-- THREE STATES, NOT TWO. The desk needs to tell these apart, because the
-- right next action differs for each:
--
--   nothing            never tried to pay        collect on arrival
--   paid_attempt_at    opened the UPI app and    check the account, or
--                      never came back           ask for a screenshot
--   paid_claim_at      said they paid            check it / view the proof
--   paid_at            the academy has it        done
--
-- The middle one is new and is the case that used to vanish: a customer
-- who taps Pay, pays, and closes the tab without answering the question
-- left no trace at all. Now the tap itself is recorded, so an unpaid
-- booking that was *attempted* looks different from one that was ignored.
--
-- SILENCE STILL MEANS UNPAID. None of these columns is money. paid_at is
-- set by collect_booking() when a human has seen the funds, and nothing a
-- customer can reach writes it. A booking whose customer never came back
-- is simply unpaid, which is the safe default and the existing behaviour.
--
-- THE BUCKET ALREADY EXISTED with staff-only policies, so an anonymous
-- customer could not upload into it. One INSERT policy fixes that, shaped
-- exactly like member_docs_anon_w: write into a folder named for a real
-- academy, and nothing else — no read, no list, no overwrite, no delete.
-- ============================================================

alter table bookings add column if not exists paid_attempt_at timestamptz;
alter table bookings add column if not exists paid_proof_path text;

comment on column bookings.paid_attempt_at is
  'When the customer OPENED the UPI app from the booking page. Not a payment and not a claim — it only says an attempt was made, so a booking nobody tried to pay looks different from one where they tried and went quiet.';
comment on column bookings.paid_proof_path is
  'Object name in the payment-proofs bucket: the screenshot the customer sent. Evidence for a human to look at, never validated by the database.';

/* Anonymous upload, INSERT only, into a folder named for a real academy.
   The customer is anonymous by definition — they have no login — and the
   folder guard is what stops one academy's bucket being filled from
   another's page. */
drop policy if exists payment_proofs_anon_w on storage.objects;
create policy payment_proofs_anon_w on storage.objects
  for insert to anon
  with check (bucket_id = 'payment-proofs'
              and tenant_exists((storage.foldername(name))[1]));

-- ------------------------------------------------------------
-- One function for every step the customer can take.
-- ------------------------------------------------------------
create or replace function public.claim_booking_payment(
  p_tenant     text,
  p_ids        text[],
  p_phone      text,
  p_ref        text    default null,
  p_proof_path text    default null,
  p_attempt    boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_phone text; v_ref text; v_n int;
begin
  if not tenant_exists(p_tenant) then raise exception 'unknown academy'; end if;

  /* THE PHONE IS THE KEY: a caller can only speak for bookings they made.
     Without it a guessed id would let a stranger mark somebody else's
     booking, or attach a screenshot to it. */
  v_phone := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 10);
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  if p_ids is null or array_length(p_ids, 1) is null then
    raise exception 'nothing to mark';
  end if;
  if array_length(p_ids, 1) > 48 then raise exception 'too many bookings at once'; end if;

  v_ref := nullif(regexp_replace(coalesce(p_ref,''), '\s', '', 'g'), '');
  if v_ref is not null and length(v_ref) > 32 then
    raise exception 'that reference is too long';
  end if;

  /* THE PATH MUST BELONG TO THIS ACADEMY. The caller is anonymous and
     chose this string; without the check a booking could be made to point
     at another tenant's object. Same guard submit_application uses. */
  if p_proof_path is not null and p_proof_path not like (p_tenant || '/%') then
    raise exception 'That file does not belong to this academy.';
  end if;

  if p_attempt then
    /* Just "they opened the app". coalesce keeps the FIRST attempt: the
       interesting fact is when they started trying, and a customer who
       taps Pay three times has not tried three times. */
    update bookings
       set paid_attempt_at = coalesce(paid_attempt_at, now())
     where tenant_id = p_tenant and id = any(p_ids) and phone = v_phone
       and status <> 'cancelled' and paid_at is null;
  else
    update bookings
       set paid_claim_at   = now(),
           paid_claim_ref  = coalesce(v_ref, paid_claim_ref),
           paid_proof_path = coalesce(p_proof_path, paid_proof_path),
           /* Saying "I paid" implies having tried, so a claim with no
              recorded attempt backfills one rather than leaving a state
              the desk cannot read. */
           paid_attempt_at = coalesce(paid_attempt_at, now())
     where tenant_id = p_tenant and id = any(p_ids) and phone = v_phone
       and status <> 'cancelled' and paid_at is null;
  end if;

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'noted', v_n,
                            'kind', case when p_attempt then 'attempt' else 'claim' end);
end
$function$;

revoke execute on function public.claim_booking_payment(text, text[], text, text, text, boolean) from public;
grant  execute on function public.claim_booking_payment(text, text[], text, text, text, boolean)
  to anon, authenticated, service_role;

/* The four-argument version is hours old and has one caller, but leaving
   it would make every four-argument call ambiguous. */
drop function if exists public.claim_booking_payment(text, text[], text, text);

-- ------------------------------------------------------------
-- Prove it across every state, and clean up.
-- ------------------------------------------------------------
do $$
declare r jsonb; c jsonb; d date := current_date + 73; ids text[] := '{}';
        v_row bookings; v_err text; v_path text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  r := request_booking('ska','astro',d,9,'ZZ Proof Probe','9000000801');  ids := ids || (r->>'id');
  r := request_booking('ska','matting',d,9,'ZZ Proof Probe','9000000801'); ids := ids || (r->>'id');
  v_path := 'ska/pay/probe/shot.jpg';

  -- 1. they open the UPI app: an attempt, and nothing more
  c := claim_booking_payment('ska', ids, '9000000801', null, null, true);
  if (c->>'noted')::int <> 2 or (c->>'kind') <> 'attempt' then
    raise exception 'attempt not recorded: %', c;
  end if;
  select * into v_row from bookings where id = ids[1];
  if v_row.paid_attempt_at is null then raise exception 'no attempt stamped'; end if;
  if v_row.paid_claim_at is not null or v_row.paid_at is not null then
    raise exception 'an attempt was treated as a payment';
  end if;

  -- 2. tapping Pay again keeps the FIRST attempt
  declare v_first timestamptz := v_row.paid_attempt_at; begin
    perform pg_sleep(0.05);
    perform claim_booking_payment('ska', ids, '9000000801', null, null, true);
    select * into v_row from bookings where id = ids[1];
    if v_row.paid_attempt_at <> v_first then
      raise exception 'a second tap moved the first attempt';
    end if;
  end;

  -- 3. they come back and send a screenshot
  c := claim_booking_payment('ska', ids, '9000000801', null, v_path, false);
  if (c->>'noted')::int <> 2 or (c->>'kind') <> 'claim' then
    raise exception 'claim not recorded: %', c;
  end if;
  select * into v_row from bookings where id = ids[1];
  if v_row.paid_proof_path <> v_path then raise exception 'proof not stored'; end if;
  if v_row.paid_claim_at is null then raise exception 'claim not stamped'; end if;
  -- AND THE MONEY IS STILL UNTOUCHED
  if v_row.paid_at is not null or v_row.paid_mode is not null or v_row.status <> 'pending' then
    raise exception 'a screenshot moved the money columns';
  end if;

  -- 4. a claim with NO attempt on record backfills one
  declare v3 text; begin
    r := request_booking('ska','astro',d,10,'ZZ Proof Probe','9000000801');
    v3 := r->>'id'; ids := ids || v3;
    perform claim_booking_payment('ska', array[v3], '9000000801', null, null, false);
    select * into v_row from bookings where id = v3;
    if v_row.paid_attempt_at is null then
      raise exception 'a claim left no attempt behind it';
    end if;
  end;

  -- 5. another academy's path is refused
  begin
    perform claim_booking_payment('ska', ids, '9000000801', null, 'leo/pay/x.jpg', false);
    raise exception 'accepted another academy''s file';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That file does not belong%' then raise; end if;
  end;

  -- 6. a stranger's phone marks nothing
  c := claim_booking_payment('ska', ids, '9000000899', null, v_path, false);
  if (c->>'noted')::int <> 0 then raise exception 'a stranger attached a screenshot'; end if;

  -- 7. once collected, later noise is ignored
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  perform collect_booking(ids[1], 'UPI', 'probe', null);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  c := claim_booking_payment('ska', array[ids[1]], '9000000801', null, null, false);
  if (c->>'noted')::int <> 0 then raise exception 'a collected booking took a new claim'; end if;

  -- 8. a SECOND screenshot replaces the first
  perform claim_booking_payment('ska', array[ids[2]], '9000000801', null, 'ska/pay/probe/second.jpg', false);
  select * into v_row from bookings where id = ids[2];
  if v_row.paid_proof_path <> 'ska/pay/probe/second.jpg' then
    raise exception 'a newer screenshot did not replace the old one';
  end if;

  delete from bookings where tenant_id='ska' and id = any(ids);
  if exists (select 1 from bookings where tenant_id='ska' and name = 'ZZ Proof Probe') then
    raise exception 'probe bookings survived';
  end if;
  if exists (select 1 from rpc_audit()) then
    raise exception 'rpc_audit is not empty: %', (select string_agg(fn, ', ') from rpc_audit());
  end if;
end $$;
