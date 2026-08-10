#!/usr/bin/env python3
"""
GenAlpha -> platform transform, proved OFFLINE.

Reads the verified export in _archive/genalpha-premerge-*/ and produces the
rows that WOULD be inserted into the platform's shared tables. Touches no
database. Nothing here writes anywhere except a local output directory.

The point is to fail here, on a laptop, rather than half-way through a
migration of a live academy's data.

What it proves before any migration runs:
  · every GenAlpha student maps to exactly one member and one enrollment
  · the uuid -> bigint remap is total and collision-free, and reversible
  · derived enrollments satisfy the platform's NOT NULL columns
  · renewal_on comes from GenAlpha's own student_paid_through_date()
  · money survives: sum(student_payments.amount) == sum(payments.amount)
  · no value silently truncates (payments.amount is integer on the platform,
    numeric on GenAlpha)

Usage:  python3 genalpha_transform.py <archive-dir> [--out DIR]
"""

import json, sys, os, re
from collections import defaultdict
from datetime import date, datetime

TENANT = "genalpha"


def load(arc, name):
    p = os.path.join(arc, name + ".json")
    with open(p) as f:
        return json.load(f)


def d(v):
    """Parse a date-ish value to date, or None."""
    if not v:
        return None
    s = str(v)[:10]
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        return None


class Result:
    def __init__(self):
        self.rows = defaultdict(list)
        self.problems = []
        self.notes = []

    def add(self, table, row):
        self.rows[table].append(row)

    def problem(self, msg):
        self.problems.append(msg)

    def note(self, msg):
        self.notes.append(msg)


def transform(arc):
    r = Result()
    students = load(arc, "students")
    payments = load(arc, "student_payments")
    attendance = load(arc, "attendance")
    timeline = load(arc, "student_timeline")
    admissions = load(arc, "admissions")
    # GenAlpha's OWN answer to "what is this student paid through?".
    # Exported from student_paid_through_date() rather than recomputed.
    paid_through = {p["student_id"]: p["paid_through"]
                    for p in load(arc, "_paid_through")}
    expenses = load(arc, "academy_expenses")

    # ---------------------------------------------------------------
    # 1. The uuid -> bigint bridge.
    #
    # Platform ids are bigint identity columns. GenAlpha is uuid
    # throughout. We assign synthetic sequential ids here ONLY to prove
    # the mapping is total and collision-free; the real migration lets
    # Postgres assign them and captures the mapping via RETURNING.
    #
    # The legacy uuid is preserved in genalpha.student_details so the
    # compatibility views can keep serving uuids to the existing app.
    # ---------------------------------------------------------------
    member_id = {}
    for i, s in enumerate(sorted(students, key=lambda x: str(x["id"])), start=1):
        member_id[s["id"]] = i
    if len(member_id) != len(students):
        r.problem(f"uuid collision: {len(students)} students -> {len(member_id)} ids")

    # ---------------------------------------------------------------
    # 2. centres and batches, DERIVED — not invented.
    #    enrollments.centre_id is NOT NULL, so one centre must exist.
    #    students.time_slot holds the real batch structure.
    # ---------------------------------------------------------------
    r.add("centres", {
        "tenant_id": TENANT, "code": "GA", "name": "GenAlpha Cricket Academy",
        "short_name": "GenAlpha", "active": True, "sort": 1,
    })
    slots = sorted({s.get("time_slot") for s in students if s.get("time_slot")})
    batch_no = {}
    for i, slot in enumerate(slots, start=1):
        batch_no[slot] = i
        r.add("batches", {
            "tenant_id": TENANT, "centre_ref": "GA",
            "code": "GA-" + re.sub(r"[^A-Za-z0-9]", "", slot).upper(),
            "name": f"Cricket {slot}", "sport": "cricket",
            "days": [1, 2, 3, 4, 5], "start_time": None, "end_time": None,
            "_derived_from_time_slot": slot, "active": True, "sort": i,
        })
    r.note(f"{len(slots)} batches derived from time_slot: {', '.join(slots)}")

    # ---------------------------------------------------------------
    # 3. students -> members (+ the GenAlpha side table for the rest)
    # ---------------------------------------------------------------
    MEMBER_COLS = {
        "name", "phone", "program", "joined", "valid_till", "status", "venue",
        "parent_name", "parent_phone", "alt_phone", "dob", "gender", "school",
        "grade", "address", "notes", "whatsapp_status", "discontinued_on",
    }
    carried, dropped = set(), set()

    for s in students:
        mid = member_id[s["id"]]
        r.add("members", {
            "_id": mid, "tenant_id": TENANT,
            "name": s.get("name"),
            # GenAlpha has no student phone; the parent's number is the contact
            "phone": s.get("parent_contact_no"),
            "parent_name": s.get("father_guardian_name"),
            "parent_phone": s.get("parent_contact_no"),
            "alt_phone": s.get("alternate_contact_no"),
            "school": s.get("school_college"),
            "grade": s.get("grade"),
            "address": s.get("address"),
            "joined": s.get("join_date"),
            "status": "discontinued" if s.get("discontinued") else "active",
            "discontinued_on": s.get("discontinued_at"),
            "program": "Cricket",
            "notes": s.get("comments"),
            "whatsapp_status": s.get("whatsapp_contact_status"),
        })
        # everything members has no column for -> the tenant-owned side table
        extras = {k: v for k, v in s.items()
                  if k not in {"id", "name", "father_guardian_name", "parent_contact_no",
                               "alternate_contact_no", "school_college", "grade", "address",
                               "join_date", "discontinued", "discontinued_at", "comments",
                               "whatsapp_contact_status", "created_at", "updated_at"}}
        carried |= set(extras)
        r.add("genalpha.student_details", {
            "member_ref": mid, "legacy_uuid": s["id"], **extras,
        })

        # -----------------------------------------------------------
        # 4. the enrollment — DERIVED from fields that already exist
        # -----------------------------------------------------------
        # renewal_on comes from GenAlpha's own student_paid_through_date().
        #
        # It is NOT derived from students.renewals. That was the first
        # version, and it was wrong in the worst possible direction: it
        # called 34 of 47 active students overdue when GenAlpha's own
        # function says only 12 are, and it matched paid_through for
        # exactly ZERO students. Going live on it would have had
        # reminder_queue() chase 34 paid-up families on day one.
        #
        # This is the house rule applied to somebody else's house: the
        # tenant's money logic already exists and is tested against real
        # families. Read it, do not reimplement it.
        renewal_on = paid_through.get(s["id"])
        if not renewal_on:
            renewal_on = s.get("join_date")
            r.note(f"member {mid}: student_paid_through_date() returned null; "
                   f"renewal_on = join_date")

        months = [p.get("months_covered") for p in payments if p["student_id"] == s["id"]]
        months = [m for m in months if m]
        r.add("enrollments", {
            "tenant_id": TENANT, "member_ref": mid, "centre_ref": "GA",
            "batch_ref": batch_no.get(s.get("time_slot")),
            "sport": "cricket",
            "plan_months": max(months) if months else 1,
            "joined_on": s.get("join_date"),
            "renewal_on": renewal_on,
            "status": "discontinued" if s.get("discontinued") else "active",
            "discontinued_on": s.get("discontinued_at"),
        })

    # ---------------------------------------------------------------
    # 5. payments — the money must survive exactly
    # ---------------------------------------------------------------
    src_total = 0.0
    dst_total = 0
    truncated = 0
    for p in payments:
        mid = member_id.get(p["student_id"])
        if mid is None:
            r.problem(f"payment {p['id']} references an unknown student")
            continue
        amt = float(p.get("amount") or 0)
        src_total += amt
        # platform payments.amount is INTEGER
        as_int = int(round(amt))
        if abs(as_int - amt) > 1e-9:
            truncated += 1
        dst_total += as_int
        merch = (p.get("plan_type") == "jersey_pair") or float(p.get("jersey_amount") or 0) > 0
        r.add("payments", {
            "tenant_id": TENANT, "member_ref": mid, "amount": as_int,
            "mode": p.get("payment_type"), "on_date": p.get("paid_on"),
            "months": p.get("months_covered"),
            "kind": "merchandise" if merch else "fee",
            "status": "paid" if p.get("verification_status") in (None, "verified") else "pending_verification",
            "ref": p.get("payment_reference"), "note": p.get("comment"),
            "proof_path": p.get("proof_path"), "collected_by": p.get("recorded_by"),
        })
    if truncated:
        r.problem(f"{truncated} payments have non-integer amounts; "
                  f"platform payments.amount is integer. Rupee difference: "
                  f"{src_total - dst_total:.2f}")

    # ---------------------------------------------------------------
    # 6. attendance — person_id is TEXT on the platform, so the uuid fits
    # ---------------------------------------------------------------
    for a in attendance:
        r.add("attendance", {
            "tenant_id": TENANT, "date": a.get("attendance_date"),
            "kind": "member", "person_id": str(a["student_id"]), "present": True,
        })

    # 7. timeline, applications, expenses
    for t in timeline:
        mid = member_id.get(t["student_id"])
        if mid is None:
            r.problem(f"timeline {t['id']} references an unknown student")
            continue
        r.add("member_timeline", {
            "tenant_id": TENANT, "member_ref": mid, "kind": t.get("event_type"),
            "title": t.get("title"), "body": t.get("details"),
            "at": t.get("created_at"),
            "meta": {"changed_by": t.get("changed_by"), "event_date": t.get("event_date")},
        })
    for a in admissions:
        r.add("applications", {
            "tenant_id": TENANT, "name": a.get("applicant_name"),
            "phone": a.get("parent_contact_no"), "parent_name": a.get("father_guardian_name"),
            "parent_phone": a.get("parent_contact_no"), "dob": a.get("date_of_birth"),
            "gender": a.get("gender"), "school": a.get("school_college"),
            "sport": "cricket", "created_at": a.get("created_at"),
        })
    for e in expenses:
        # GenAlpha names these differently; read its columns, do not assume
        # the platform's. expenses.category is NOT NULL.
        r.add("expenses", {
            "tenant_id": TENANT,
            "category": e.get("expense_type") or "Uncategorised",
            "payee": e.get("paid_by"),
            "detail": e.get("comment"),
            "amount": e.get("amount"),
            "mode": None,
            "on_date": e.get("expense_date"),
        })

    r.note(f"side table carries {len(carried)} GenAlpha-only columns: "
           + ", ".join(sorted(carried)))
    return r, src_total, dst_total


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    arc = sys.argv[1]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None

    r, src_total, dst_total = transform(arc)

    print("\n  ROWS THE MIGRATION WOULD PRODUCE")
    print("  " + "-" * 52)
    for t in sorted(r.rows):
        print(f"    {t:<34}{len(r.rows[t]):>8}")
    print("  " + "-" * 52)
    print(f"    {'TOTAL':<34}{sum(len(v) for v in r.rows.values()):>8}")

    print("\n  MONEY")
    print(f"    GenAlpha total   {src_total:>12,.2f}")
    print(f"    platform total   {dst_total:>12,d}")
    print(f"    difference       {src_total - dst_total:>12,.2f}")

    # NOT NULL checks against the real platform constraints
    print("\n  CONSTRAINT CHECKS")
    bad = 0
    for e in r.rows["enrollments"]:
        for col in ("member_ref", "centre_ref", "joined_on"):
            if e.get(col) in (None, ""):
                bad += 1
                r.problem(f"enrollment for member {e.get('member_ref')} has null {col}")
    for m in r.rows["members"]:
        if not m.get("name"):
            bad += 1
            r.problem(f"member {m.get('_id')} has no name")
    print(f"    NOT NULL violations: {bad}")
    print(f"    members == enrollments: "
          f"{len(r.rows['members'])} == {len(r.rows['enrollments'])} "
          f"{'OK' if len(r.rows['members']) == len(r.rows['enrollments']) else 'MISMATCH'}")

    if r.notes:
        print("\n  NOTES")
        for n in r.notes[:8]:
            print(f"    - {n}")
        if len(r.notes) > 8:
            print(f"    ... and {len(r.notes) - 8} more")

    print("\n  PROBLEMS")
    if not r.problems:
        print("    none")
    else:
        seen = defaultdict(int)
        for p in r.problems:
            seen[re.sub(r"\d+", "N", p)] += 1
        for p, n in sorted(seen.items(), key=lambda x: -x[1]):
            print(f"    [{n:>4}] {p}")

    if out:
        os.makedirs(out, exist_ok=True)
        for t, rows in r.rows.items():
            with open(os.path.join(out, t.replace(".", "_") + ".json"), "w") as f:
                json.dump(rows, f, indent=1, default=str)
        print(f"\n  wrote {len(r.rows)} files to {out}")

    sys.exit(1 if r.problems else 0)


if __name__ == "__main__":
    main()
