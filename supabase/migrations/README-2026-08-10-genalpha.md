# The 2026-08-10 GenAlpha migrations are not in this repo

Sixteen files named `2026-08-10[a-k]-genalpha-*.sql` were applied to the
platform on 2026-08-10 and are recorded in `schema_migrations`. They are
**deliberately absent from git.**

They embedded GenAlpha's rows as jsonb literals in order to move them —
81 children's names, 123 phone numbers, home addresses, schools, and
WhatsApp conversation content, 3.2 MB in total. Committing them put that
data in this repository, which was public at the time. It was public for
roughly one hour on 2026-08-10 (14:42–15:40) before the repo was made
private and the history purged.

**The merge those files performed has since been reverted**
(`2026-08-10k-genalpha-unstage.sql`, also purged). GenAlpha's data no
longer exists in the platform and GenAlpha is federated again, so the
files describe a state that is no longer live.

## If the merge is redone

Do not recover these files. Regenerate from the archive instead:

    python3 scripts/genalpha_transform.py \
      "../_archive/genalpha-premerge-2026-08-10" --out /tmp/out
    python3 scripts/genalpha_emit_sql.py

Both scripts are in git; only their *output* is not. The archive holds
the verified export — 18 tables, 8,868 rows — outside every repo,
because that is where personal data belongs.

Use NEW filenames. The ledger refuses an applied basename, and it is
right to.

## The lesson

A migration that carries data carries whatever that data is. Schema
migrations belong in git; rows about real children do not. Generate them
into a working directory, apply them, and let them go.

## 2026-08-11e and -11f are ledgered but empty

Both were generated with `sed` from `2026-08-10e`/`-10f`, which no longer
exist on disk — the history rewrite that purged the data-bearing
migrations took them too. `sed` wrote zero bytes, `migrate.sh` applied
zero bytes, and both were recorded as successful.

A migration runner cannot distinguish an empty file from a deliberate
no-op. The ledger rows are real; the work they claim is not.

`2026-08-11g-genalpha-attendance-fees.sql` does what those two were
supposed to do, and asserts the outcome rather than the execution.
