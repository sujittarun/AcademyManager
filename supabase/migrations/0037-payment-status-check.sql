-- 0037 — payments.status becomes a closed set
--
-- WHY
--
-- `payments.status` was free text with a default of 'paid' and no
-- constraint. Three functions write it, and between them they only ever
-- produce three values:
--
--   record_fee_payment   inserts, guarded to 'paid' | 'pending_verification'
--   confirm_payment      sets 'paid'
--   void_payment         sets 'void'
--
-- So the set was already a convention. It just was not a fact. Anything
-- reaching the table another way — a direct PostgREST write, a psql
-- session, a future function, a typo in any of them — could store
-- 'confirmd', 'refunded', 'Paid', or anything else, and the row would
-- insert, store and read back perfectly happily.
--
-- That is not hypothetical. MatchPointPride's test fixture asserted
-- against `status: 'confirmed'` — a value no function has ever written
-- and no row has ever held. Nothing rejected it, so it sat there
-- pretending to be a payment for as long as the test existed.
--
-- It matters because every consumer treats the status as meaningful:
--
--   apply_payment_coverage   returns early unless status = 'paid'
--   compute_payouts          sums only status = 'paid'
--   payout_scope_collected   sums only status = 'paid'
--   enrollment_payment_summary  filters to status = 'paid'
--   RajSportsApp             filters to "paid" / "pending_verification"
--   MatchPointPride mapping  allow-lists 'paid' (and null)
--
-- Every one of those is an allow-list, which is the right direction:
-- money that is not confirmed should not be counted. But it means an
-- unrecognised status makes a real payment SILENTLY VANISH from
-- revenue, payouts and coverage — the row is there, the money is not,
-- and nothing reports an error. A typo becomes lost income that
-- reconciles to nothing.
--
-- The constraint turns that failure from silent into loud: the bad
-- write is rejected at the point it happens, naming the value, instead
-- of being discovered months later as a number that does not add up.
--
-- WHAT THIS DOES NOT DO
--
-- It does not stop a voided payment being counted as revenue. That was
-- a client bug — MatchPointPride's mapping.ts read every row as
-- positive revenue without looking at status — and it is fixed there.
-- This constrains which values may exist, not what they mean.
--
-- SAFETY
--
-- Verified before writing: 473 rows across six tenants hold only 'paid'
-- (471) and 'pending_verification' (2). No row violates. The column is
-- already NOT NULL, so there is no NULL-passes-a-CHECK gap. All 90
-- functions in public and backup were scanned; only the three above
-- write to this table.
--
-- Shared table: this binds every tenant, including the Raj Android app,
-- which cannot be force-updated. That app only READS status, so it is
-- unaffected.

-- NO `begin;` / `commit;` IN THIS FILE.
--
-- migrate.sh already wraps it: it emits `begin;`, then this file, then
-- either the ledger insert and `commit;`, or `rollback;` for a dry run.
-- A `commit;` in here ends the RUNNER's transaction, so the trailing
-- `rollback;` has nothing to undo and is a no-op warning.
--
-- This is not theoretical. The first version of this file carried its
-- own begin/commit, and `--dry-run` applied the constraint for real
-- while printing "✓ dry run clean — Nothing was kept." The change
-- landed with no ledger row, which is the one state the ledger exists
-- to make impossible.

-- Refuse to proceed rather than let ALTER fail with a row count and no
-- names. If this ever fires, the offending values are the message.
do $$
declare
  bad text;
begin
  select string_agg(distinct status, ', ')
    into bad
    from payments
   where status not in ('paid', 'pending_verification', 'void');

  if bad is not null then
    raise exception
      'payments.status holds values outside the intended set: %. '
      'Decide whether each is a real state (add it to the constraint) '
      'or a mistake (correct the rows) before applying this.', bad
      using errcode = 'check_violation';
  end if;
end $$;

-- Idempotent because the first run of this file already added the
-- constraint, through the dry run described above. Re-running is how
-- the ledger row finally gets written.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'payments_status_valid'
       and conrelid = 'public.payments'::regclass
  ) then
    alter table public.payments
      add constraint payments_status_valid
      check (status in ('paid', 'pending_verification', 'void'));
  end if;
end $$;

comment on constraint payments_status_valid on public.payments is
  'The closed set of payment states. Written only by record_fee_payment '
  '(paid | pending_verification), confirm_payment (paid) and '
  'void_payment (void). Every consumer allow-lists on this column, so an '
  'unrecognised value does not raise — it silently drops the payment out '
  'of revenue, payouts and coverage. Adding a state means adding it here '
  'AND to those consumers.';
