/* ============================================================
   Half-day staff attendance: `am` and `pm` on `attendance`.

   BELONGS IN: AcademyManager/supabase/migrations/
   APPLY WITH: scripts/migrate.sh --scope shared <this file>
   (It alters a shared table, so it may not live in a tenant repo and
   migrate.sh will refuse it at tenant scope.)

   MPP's owner runs two shifts and needs to mark a coach in for the
   morning, the evening, or both. The table held one row per person per
   day (PK: tenant_id, date, kind, person_id) and one boolean, so there
   was nowhere to put it.

   ---------------------------------------------------------------
   WHY THIS IS SAFE FOR THE OTHER FIVE TENANTS
   ---------------------------------------------------------------

   Measured before writing this, not assumed:

   · Raj — whose primary feature IS attendance — has ZERO rows in this
     table. Raj's attendance is `sessions` (244) + `attendance_records`
     (1,883), an entirely different pair of tables. Nothing here can
     reach Raj's numbers.
   · Rows here are leo 9 staff / 23 member, matchpoint 2 staff / 7
     member, machaxi 5 member, mpp 140 staff.
   · NO shared function reads this table. The only pg_proc whose source
     mentions it is `is_shared_object`, which merely lists table names
     as strings. `attendance_roster/history/dashboard/mark_attendance`
     all read the sessions model instead — the split `0041` documented.
   · One view references it, `player_development_summary`. It names its
     columns (`at.present`, `at.kind`, `at.date`) rather than `select *`,
     and filters `kind = 'member'`, so it cannot see a staff row. A
     `select *` view would have been fine anyway — Postgres expands the
     star at definition time — but it was checked rather than assumed.
   · The three RLS policies are already tenant-scoped through
     auth_tenant(); a new column inherits them.

   Both columns are NULLABLE with no default, so every existing row and
   every future row written by another tenant is untouched: they stay
   NULL and no other app has to know these exist.

   ---------------------------------------------------------------
   THE CONTRACT, so trends do not quietly change meaning
   ---------------------------------------------------------------

   `present` REMAINS the single answer to "did this person work that
   day". It is not deprecated and it is not derived by any reader. Every
   existing chart in every tenant keeps reading it and keeps getting the
   same number it got yesterday.

   `am` / `pm` only REFINE that answer, and only where someone fills
   them in:

     present=true,  am=NULL, pm=NULL   a full day (all 140 mpp rows,
                                       and every leo/matchpoint row)
     present=true,  am=true, pm=false  a morning only  -> half a day
     present=true,  am=false, pm=true  an evening only -> half a day
     present=true,  am=true, pm=true   both shifts     -> a full day
     present=false, am=false, pm=false absent

   NULL therefore means "nobody said", and a reader counting days must
   treat a present row with NULL halves as a FULL day — which is what it
   has always meant. That is what keeps history stable: this migration
   deliberately does NOT backfill am/pm, because writing am=true,pm=true
   across 140 existing rows would assert two shifts were worked on days
   nobody recorded shifts for.

   The check constraint is scoped to mpp by name, per PLATFORM.md: a
   bare CHECK on a shared table is a law for all six. It stops `present`
   drifting out of step with the halves, which is the whole basis of the
   safety argument above.
   ============================================================ */

alter table public.attendance
  add column if not exists am boolean,
  add column if not exists pm boolean;

comment on column public.attendance.present is
  'Did this person work that day. THE answer to that question for every '
  'tenant; am/pm only refine it. Never derive this from am/pm on read — '
  'a row with NULL halves is a full day.';

comment on column public.attendance.am is
  'Optional morning shift. NULL = nobody said, which for a present row '
  'means a full day. Only mpp fills this in.';

comment on column public.attendance.pm is
  'Optional evening shift. NULL = nobody said, which for a present row '
  'means a full day. Only mpp fills this in.';

/* `present` must agree with the halves WHERE THE HALVES ARE SET. Named
   for mpp so the other five are not bound by a rule they never asked
   for. Written so a NULL half can never make the predicate NULL and
   wave a bad row through. */
alter table public.attendance
  drop constraint if exists attendance_mpp_halves_agree;

alter table public.attendance
  add constraint attendance_mpp_halves_agree check (
    tenant_id <> 'mpp'
    or (am is null and pm is null)
    or present = (coalesce(am, false) or coalesce(pm, false))
  );

/* Prove the claims rather than assert them. Raises, so the whole
   migration rolls back if any of it is untrue. */
do $$
declare
  n_raj      int;
  n_nonnull  int;
  n_mpp      int;
begin
  select count(*) into n_raj from attendance where tenant_id = 'raj';
  if n_raj <> 0 then
    raise exception 'raj now has % rows in attendance — re-read the safety note above', n_raj;
  end if;

  -- Nobody's history moved: every pre-existing row is still NULL/NULL.
  select count(*) into n_nonnull from attendance where am is not null or pm is not null;
  if n_nonnull <> 0 then
    raise exception '% rows already carry am/pm — this migration should not have backfilled', n_nonnull;
  end if;

  select count(*) into n_mpp from attendance where tenant_id = 'mpp' and present;
  raise notice 'attendance half-day columns added; % mpp present-rows remain full days', n_mpp;
end $$;
