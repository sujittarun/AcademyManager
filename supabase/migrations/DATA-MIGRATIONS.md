# Migrations that carry real rows are not committed

Most files here are DDL, functions, policies and checks. A few load
actual data, and those embed real families as SQL literals — children's
names, parent phone numbers, home addresses.

Those files are `.gitignore`d. This is deliberate.

## Why it is safe to leave them out

`schema_migrations` records every applied file by **basename + sha256**,
and that ledger lives in the database, not in git. The runner's refusal
to re-apply a file, and its louder refusal when a file has changed, both
work off the database row. Nothing about the ledger needs the file to be
tracked.

## Where they actually live

Beside the export they were generated from:

    ../_archive/genalpha-premerge-2026-08-10-2139/

with the emitting scripts in `scripts/genalpha_transform.py` and
`scripts/genalpha_emit_sql.py`. The data can be regenerated from the
archive; the archive is the thing to keep.

## Already-committed history

Migrations applied before this rule existed **do** contain real GenAlpha
family phone numbers — roughly 125 distinct numbers across
`2026-08-11b`, `-11c`, `-11d`, `-11kz` and `-11m`. The repository is
private, so they are not exposed, but they are in git history and a
`git filter-repo` pass plus a force-push is what removes them.

The mpp and demo seed files also match a phone-number pattern; those are
generated (`90000001xx`) or the venue's own published business number,
and are not a concern.

## The rule going forward

If a migration contains a row of somebody's personal data, it does not
get committed. Split it: DDL and checks in a tracked file, the rows in an
untracked one.
