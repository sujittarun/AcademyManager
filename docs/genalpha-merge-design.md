# Merging GenAlpha into the platform — the design

Goal: one Supabase project instead of two, without putting `genalpha_*`
tables in the shared `public` schema and without rewriting a live app.

## The two facts that shape everything

**1. Primary keys are incompatible.** GenAlpha is `uuid` throughout;
the platform is `bigint`. `students.id`, `student_payments.id`,
`attendance.id` are all uuid, and the app fetches and stores by uuid.

**2. `members` has no jsonb column.** GenAlpha carries fields the shared
table has nowhere to put — `jersey_size`, `jersey_pairs`, `reg_no`,
`time_slot`, `renewals` (an array), `admission_id`, `payment_upi_id`,
batting/bowling style — and the platform rule forbids adding a column to
a shared table for one tenant.

Both point at the same answer, and PLATFORM.md already prescribes it:

> **Tenant-specific field** → a tenant-owned table keyed on the shared
> row's id, or `config` jsonb. Not a new column on `members`.

So the side table is not a last resort. It is the documented pattern.
What makes it *smart* rather than a dump is that it also carries
`legacy_uuid`, which is the bridge between GenAlpha's uuid world and the
platform's bigint world.

---

## Four layers

### Layer 1 — shared nouns go to the shared tables, unchanged

| GenAlpha | → platform | note |
|---|---|---|
| `students` | `members` | name, dob, gender, school, address, parent contact all map |
| `student_payments` | `payments` | amount, mode, on_date, months, proof_path map |
| `attendance` (1,451) | `attendance` with `kind='member'` | **`attendance.person_id` is `text`** — GenAlpha's uuid drops straight in, no remap |
| `student_timeline` (3,030) | `member_timeline` | has a `meta jsonb` column for the leftovers |
| `admissions` | `applications` | name, phone, parent, dob, gender, school map |

These stay generic. No tenant name appears in `public`.

### Layer 2 — one GenAlpha-owned side table for the extras

```
genalpha.student_details (
  member_id    bigint primary key references public.members(id),
  legacy_uuid  uuid unique not null,   -- the bridge
  reg_no       bigint,
  time_slot    text,
  jersey_size  text,
  jersey_pairs integer,
  renewals     jsonb,
  batting      text,
  bowling      text[],
  ...
)
```

`legacy_uuid` is the whole trick. It lets the app keep using uuids while
the platform uses bigints, and it makes Layer 4 possible.

### Layer 3 — genuinely new nouns become a gated module

The admission-AI subsystem is a real case-3 noun: `admission_intake_*`,
`admission_ai_extractions`, `admission_payment_claims` — 7 tables the
platform has no equivalent for. Treat it exactly like MatchPoint's
player-progress cluster: its own tables, `tenant_id`-scoped, RLS and
`revoke … from public` in the **first** migration, gated on
`config.modules.admissionsAI`.

Worth noting: AI-assisted admissions intake is a feature other academies
would plausibly want. If so it belongs in `public` with generic names,
not in a GenAlpha schema. That is a product decision, not a technical one.

`academy_expenses` is likewise a new noun (the platform has no expenses
concept). `registration_counters` and `system_settings` collapse into
`tenants.config`.

`whatsapp_webhook_events`, `whatsapp_flow_events` and the 253 MB of
`net._http_response` are logs. Drop them; do not migrate.

### Layer 4 — compatibility views, so the app barely changes

A `genalpha` schema holding views shaped like the app's current tables:

```sql
create view genalpha.students as
  select d.legacy_uuid              as id,      -- app still sees a uuid
         m.name, m.dob, m.gender, m.school, m.address,
         m.parent_name              as father_guardian_name,
         m.parent_phone             as parent_contact_no,
         m.alt_phone                as alternate_contact_no,
         m.joined                   as join_date,
         (m.status = 'discontinued') as discontinued,
         d.reg_no, d.time_slot, d.jersey_size, d.jersey_pairs, d.renewals
    from public.members m
    join genalpha.student_details d on d.member_id = m.id
   where m.tenant_id = 'genalpha';
```

Add `genalpha` to the project's exposed PostgREST schemas (Supabase
dashboard → API settings). The app then changes **two constants** — the
project URL and the anon key — and keeps its table names, its column
names and its uuid ids.

Writes go one of two ways: `INSTEAD OF` triggers on the views, or the app
moves its money writes onto `record_fee_payment()` — which the house rule
wants regardless.

### Why this beats `genalpha_*` tables in `public`

- `public` stays generic; no customer's name in the shared namespace
- data lives **once**, in shared tables, computed by the shared money
  functions — the house rule is satisfied rather than worked around
- the app rewrite collapses from "everything" to "two constants plus
  write paths"
- if GenAlpha ever leaves, you `drop schema genalpha cascade`

---

## What this design does NOT solve, stated plainly

**1. GenAlpha has no enrollments, and the platform's money model needs
them.** `renewal_on` lives on `enrollments`; `record_fee_payment()` rolls
it forward; `reminder_queue()` reads it. GenAlpha denormalises the same
idea onto `students.renewals` and `student_payments.plan_type /
cycle_start_date / months_covered`. Every student needs a synthesised
enrollment, and `enrollments.centre_id` is NOT NULL — so GenAlpha needs
at least one `centres` row it does not currently have. **This is the
crux of the whole merge**, not the column mapping.

**2. `payments.amount` is `integer` on the platform, `numeric` on
GenAlpha.** Jersey amounts with paise would truncate. Either round on
migration and accept the loss, or widen the column — and widening a
shared column is a change for all six tenants.

**3. Jersey sales.** `jersey_amount`, `jersey_pairs`, `jersey_size` are
merchandise. The platform has no such concept, and folding merchandise
revenue into `payments` will distort `tenant_revenue_streams()` and GMV.

**4. Auth.** 3 users on GenAlpha's project must be recreated with
`app_metadata {am_role, tenant_id:'genalpha'}`, and every existing
session is invalidated at cutover.

**5. RLS.** GenAlpha is single-tenant and almost certainly permissive.
On the platform every read passes a `tenant_id` policy. The views must be
`security_invoker` or they become a hole that ignores RLS.

---

## Honest verdict

The design is sound and avoids the ugly fallback. The work is not in the
column mapping — that is a day. It is in items 1–3 above: inventing an
enrollment model for a tenant that has none, and deciding what happens to
merchandise revenue.

Against a saving of **USD 10/month**.
