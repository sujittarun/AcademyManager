-- ============================================================
-- 2026-08-19ze · "I have paid" is a claim, not a payment
-- scope: shared
--
-- The booking page hands the customer a upi:// link. They leave for GPay,
-- pay, and come back to a page that still says "Pay ₹900 by UPI" — because
-- a deep link has no callback and nothing on this platform learns anything.
-- The customer reads that as a failed payment; the academy sees a pending
-- booking indistinguishable from one nobody paid for.
--
-- The fix is NOT to believe them. paid_at means the academy has the money
-- and is set by collect_booking() when a human has seen it in the account.
-- Nothing a customer taps may ever write that column, or the ledger starts
-- carrying money that does not exist.
--
-- So two new columns that say something weaker and true:
--
--   paid_claim_at   when the customer said they had paid
--   paid_claim_ref  the UPI reference they typed, if they typed one
--
-- The desk sees "customer says paid" on the booking and knows to look for
-- it; the Finance page still counts only paid_at. A claim is a hint for a
-- human, never an entry in the books.
--
-- WHY A SHARED COLUMN and not tenant config: any academy handed a UPI deep
-- link has exactly this gap. It is platform vocabulary, and a shared
-- function reads it.
-- ============================================================

alter table bookings add column if not exists paid_claim_at  timestamptz;
alter table bookings add column if not exists paid_claim_ref text;

comment on column bookings.paid_claim_at is
  'When the CUSTOMER said they had paid, from the booking page. Not proof of anything: paid_at is the academy confirming the money arrived. Finance counts paid_at only.';
comment on column bookings.paid_claim_ref is
  'The UPI reference the customer typed, if any. A hint for reconciliation, never validated.';

-- ------------------------------------------------------------
-- The customer's own claim. Anonymous, because the customer is.
-- ------------------------------------------------------------
create or replace function public.claim_booking_payment(
  p_tenant text,
  p_ids    text[],
  p_phone  text,
  p_ref    text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_phone text; v_ref text; v_n int;
begin
  if not tenant_exists(p_tenant) then raise exception 'unknown academy'; end if;

  /* THE PHONE IS THE KEY, exactly as in public_booking_total: a caller can
     only speak for bookings they made. Without it a guessed id would let a
     stranger mark somebody else's booking as paid. */
  v_phone := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 10);
  if length(v_phone) < 10 then raise exception 'valid phone required'; end if;
  if p_ids is null or array_length(p_ids, 1) is null then
    raise exception 'nothing to mark';
  end if;
  if array_length(p_ids, 1) > 48 then raise exception 'too many bookings at once'; end if;

  /* A UPI reference is digits, usually twelve. Kept as text and NOT
     validated beyond shape — a customer mistyping it must not lose the
     claim, and the academy is going to eyeball it against their account
     anyway. */
  v_ref := nullif(regexp_replace(coalesce(p_ref,''), '\s', '', 'g'), '');
  if v_ref is not null and length(v_ref) > 32 then
    raise exception 'that reference is too long';
  end if;

  update bookings
     set paid_claim_at  = now(),
         paid_claim_ref = coalesce(v_ref, paid_claim_ref)
   where tenant_id = p_tenant
     and id = any(p_ids)
     and phone = v_phone
     and status <> 'cancelled'
     /* Already collected? Then the academy knows more than the customer
        does, and a claim would only add noise. */
     and paid_at is null;

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'noted', v_n);
end
$function$;

revoke execute on function public.claim_booking_payment(text, text[], text, text) from public;
grant  execute on function public.claim_booking_payment(text, text[], text, text)
  to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- rpc_audit() has to know, or it stops being empty. Copied verbatim from
-- the live definition with one entry added.
-- ------------------------------------------------------------
create or replace function public.rpc_audit()
 returns table(fn text, args text, touches text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
           'public.demo_snapshot',
           -- Added 2026-08-20. Returns a SUM and a COUNT for bookings the
           -- caller already made — never a row, never a name, never a
           -- phone. It requires the phone that is ON those bookings, so a
           -- caller can only total their own; a guessed id with the wrong
           -- number totals zero. It exists because an anonymous customer
           -- who has just booked three nets should be able to see what
           -- they owe, and adding that up in the page is the one thing
           -- this platform does not do with money.
           'public.public_booking_total',
           -- Added 2026-08-19ze. Writes paid_claim_at / paid_claim_ref and
           -- nothing else — it cannot touch paid_at, status or amount, so
           -- the worst a forged call can do is tell the desk to go and look
           -- at an account where there is no money. Phone-guarded the same
           -- way, and skipped entirely once a booking is collected.
           'public.claim_booking_payment'
         ])
     and exists (select 1 from tenant_tables tt
                  where pg_get_functiondef(p.oid) ~* ('\m' || tt.t || '\M'))
   order by 1
$function$;

-- ------------------------------------------------------------
-- Prove it, and clean up.
-- ------------------------------------------------------------
do $$
declare r jsonb; c jsonb; d date := current_date + 71; ids text[] := '{}'; v_row bookings; v_err text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  r := request_booking('ska','astro',d,9,'ZZ Claim Probe','9000000981');  ids := ids || (r->>'id');
  r := request_booking('ska','matting',d,9,'ZZ Claim Probe','9000000981'); ids := ids || (r->>'id');

  -- the customer says they paid, with a reference
  c := claim_booking_payment('ska', ids, '9000000981', '123456789012');
  if (c->>'noted')::int <> 2 then raise exception 'claim noted % rows, expected 2', c->>'noted'; end if;

  select * into v_row from bookings where id = ids[1];
  if v_row.paid_claim_at is null then raise exception 'the claim was not recorded'; end if;
  if v_row.paid_claim_ref <> '123456789012' then raise exception 'the reference was not kept'; end if;
  -- AND THE MONEY COLUMN IS UNTOUCHED. This is the whole point.
  if v_row.paid_at is not null or v_row.paid_mode is not null then
    raise exception 'a customer claim wrote the payment columns';
  end if;
  if v_row.status <> 'pending' then raise exception 'a claim changed the status'; end if;
  if v_row.amount <> 500 then raise exception 'a claim changed the amount'; end if;

  -- somebody else's phone marks nothing
  c := claim_booking_payment('ska', ids, '9000000982', '999');
  if (c->>'noted')::int <> 0 then raise exception 'a stranger claimed another persons booking'; end if;

  -- once the academy has collected it, a later claim is ignored
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  perform collect_booking(ids[1], 'UPI', 'probe', null);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  c := claim_booking_payment('ska', ids, '9000000981', '000');
  if (c->>'noted')::int <> 1 then
    raise exception 'expected only the uncollected row to take the claim, got %', c->>'noted';
  end if;

  -- a silly reference is refused rather than stored
  begin
    perform claim_booking_payment('ska', ids, '9000000981', repeat('9', 40));
    raise exception 'accepted a 40-character reference';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'that reference is too long%' then raise; end if;
  end;

  delete from bookings where tenant_id='ska' and id = any(ids);
  if exists (select 1 from bookings where tenant_id='ska' and name = 'ZZ Claim Probe') then
    raise exception 'probe bookings survived';
  end if;

  if exists (select 1 from rpc_audit()) then
    raise exception 'rpc_audit is not empty: %', (select string_agg(fn, ', ') from rpc_audit());
  end if;
end $$;
