#!/usr/bin/env python3
"""Load a researched lead CSV into sales.leads via public.sales_import().

    scripts/sales-import.py <master.csv> [--dry-run]

Why this exists rather than a psql \\copy: sales_import() is the only write
path, and it is the thing that enforces the rules -- DNC suppression on the
way in, never downgrading a verified phone with a directory one, and the
normalisation that refuses to store a number nobody can dial. A bulk COPY
would bypass every one of them.

The import is idempotent on the normalised academy name, so re-running it
after another research batch lands updates in place rather than
duplicating. That is deliberate: research arrives one vertical at a time.

The CSV holds third-party phone numbers. It is NOT committed -- see
marketing/leads/.gitignore. This script reads it from wherever you point
it and leaves the data in Postgres.
"""
import csv
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SQL = os.path.join(HERE, "_sql.py")
BATCH = 40          # keep each SQL payload well under any body limit

FIELDS = ["name", "sport", "area", "city", "contact_name", "phone",
          "phone_confidence", "phone_source_url", "website_or_social",
          "branches", "students_est", "fees_seen", "tech_signal",
          "coaching_evidence", "size_signal", "notes"]


def rows_from(path):
    out = []
    with open(path, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            name = (r.get("name") or "").strip()
            if not name:
                continue
            row = {}
            for f in FIELDS:
                v = (r.get(f) or "").strip()
                if v:
                    row[f] = v
            alts = (r.get("alt_phones") or "").split()
            if alts:
                row["alt_phones"] = alts
            # the researchers' confidence values, mapped to the check
            # constraint. Anything unrecognised becomes 'none' rather than
            # being waved through as callable.
            c = row.get("phone_confidence", "").lower()
            if c.startswith("verif"):
                row["phone_confidence"] = "verified"
            elif c.startswith("direct"):
                row["phone_confidence"] = "directory"
            elif c.startswith("malform"):
                row["phone_confidence"] = "malformed"
            else:
                row["phone_confidence"] = "none"
            out.append(row)
    return out


def run_sql(sql):
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
        fh.write(sql)
        p = fh.name
    try:
        r = subprocess.run([sys.executable, SQL, p],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("SQL failed:\n" + (r.stderr or r.stdout))
        return r.stdout.strip()
    finally:
        os.unlink(p)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)

    rows = rows_from(args[0])
    print("read %d leads from %s" % (len(rows), args[0]))
    with_phone = sum(1 for r in rows if r.get("phone"))
    print("  %d carry a phone, %d verified, %d directory" % (
        with_phone,
        sum(1 for r in rows if r.get("phone_confidence") == "verified"),
        sum(1 for r in rows if r.get("phone_confidence") == "directory")))

    if dry:
        print("\n--dry-run: first row as it would be sent:")
        print(json.dumps(rows[0], indent=2, ensure_ascii=False))
        return

    total = {"inserted": 0, "updated": 0}
    for i in range(0, len(rows), BATCH):
        chunk = rows[i:i + BATCH]
        payload = json.dumps(chunk, ensure_ascii=False)
        if "$IMPORT$" in payload:
            sys.exit("refusing: payload contains the dollar-quote tag")
        out = run_sql("select public.sales_import($IMPORT$%s$IMPORT$::jsonb);"
                      % payload)
        try:
            res = json.loads(out)[0]["sales_import"]
        except Exception:
            sys.exit("could not parse result: " + out[:400])
        total["inserted"] += res.get("inserted", 0)
        total["updated"] += res.get("updated", 0)
        print("  batch %-3d inserted=%-3s updated=%-3s total_now=%s" % (
            i // BATCH + 1, res.get("inserted"), res.get("updated"),
            res.get("total")))

    print("\ninserted %d, updated %d" % (total["inserted"], total["updated"]))
    print(run_sql("select public.sales_pipeline();"))


if __name__ == "__main__":
    main()
