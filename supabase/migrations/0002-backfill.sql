-- ============================================================
-- 0002 · Backfill the ledger
-- scope: shared
--
-- Every row below was VERIFIED against the live database before being
-- recorded — by probing for an object the file creates, not by assuming
-- it ran. The probe used is in the note column.
--
-- Deliberately NOT backfilled, because application could not be proved
-- either way (both only drop/create policies that other files also
-- touch, so their footprint is indistinguishable):
--
--   LeoTennis/supabase/lockdown.sql
--   LeoTennis/supabase/launch-reset.sql
--
-- Leaving them out is the safe direction: migrate.sh will let you apply
-- them, and --dry-run shows what they would do first. Recording them
-- wrongly would instead block a legitimate apply.
--
-- Data and test scripts are not migrations and are excluded on purpose —
-- sample-data.sql, clear-sample-data.sql, cleanup-test-data.sql,
-- seed-matchpoint-progress-scenarios.sql, test-*.sql. Those are meant to
-- stay re-runnable.
-- ============================================================

insert into schema_migrations (filename, sha256, scope, applied_by, note) values
  ('schema.sql', '0eb1a53f2ed78dfbd32d9f274c8c0c190502b6ab4482b2b00189dd28434bb3f2', 'shared', 'backfill', 'base schema; verified live: bookings + events exist'),
  ('migration-machaxi.sql', '152460f78d47fb73fe21a3ad01ab83bfbe448d314508444d309912786589a8e2', 'machaxi', 'backfill', 'verified live: tenants row machaxi'),
  ('migration-matchpoint.sql', '194455f6b74708c9fbe5dc4067ea8ddd6251a73a0544d6648a3b0a1a577db8eb', 'matchpoint', 'backfill', 'verified live: tenants row matchpoint'),
  ('player-progress-matchpoint.sql', '80ed9d5cf0bf8dadaca618b6f2720fe3852b0bf11989e49ce895165ecce73435', 'matchpoint', 'backfill', 'verified live: player_progress table'),
  ('migration-raj.sql', '3b39bc6d07ee215d9aa1bcb217b380cc5082b29854c6819dad66eed2353da0a7', 'raj', 'backfill', 'verified live: enrollments table'),
  ('migration-raj-2.sql', 'b6a9aef384ced196c5b852341123c4082ba23c84c10a15c4cecef94ebcbef9be', 'raj', 'backfill', 'verified live: policy batches_public_r'),
  ('migration-raj-3.sql', '7f6cb53283fea8a4136c693ccae77756b16fb210c69f93053672ea30e774e51f', 'raj', 'backfill', 'verified live: audit_log table'),
  ('migration-raj-4.sql', '8e6f9eb965d4f213352d6886213ece297086ce1b3db82caab87ca5d1a89ddf2e', 'raj', 'backfill', 'verified live: policy events_public_w'),
  ('migration-raj-5.sql', 'af7470c3ff33962e2f8db18e9c316ccb320e10feccda482aa5b6ae0a0572be7b', 'raj', 'backfill', 'verified live: reminder_queue contains last_reminder'),
  ('migration-raj-6.sql', '11c0fe56f98dc13bdebdbe6ee1c33e43939bd575a0784431fa2fccbeece40443', 'raj', 'backfill', 'verified live: attendance_records table'),
  ('migration-raj-7.sql', 'b826238c2e92caf4f40296b817701cc9c9e51b7843c646ce35c18e263b8aaad4', 'raj', 'backfill', 'verified live: mark_attendance()'),
  ('migration-raj-8.sql', '3361144ab2c04aba2d0d77653580bc1af62e4499bdb1586067a2bdc8b1651b87', 'raj', 'backfill', 'verified live: apply_payment_coverage(); holds record_fee_payment v2, which migration-raj.sql would revert'),
  ('cron-raj.sql', '63d65b24c4b40542c46a1464f98f2c8e5ca8f354d76196635fb76aa2cfbfd1bf', 'raj', 'backfill', 'verified live: cron jobs raj-fee-reminders-daily and -retry')
on conflict (filename) do nothing;
