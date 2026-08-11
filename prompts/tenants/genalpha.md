# GenAlpha — paste this into a chat opened in `GenAlpha/` or `GenAlphaApp/`

Paste `prompts/EXISTING-TENANT.md` first. This is what that file cannot
know: where GenAlpha specifically stands as of **2026-08-12**.

GenAlpha is the largest live tenant and the only one taking money through
WhatsApp today. **81 real families.** Treat every change as production.

---

## It moved. That is the single most important fact.

Until 2026-08-10 GenAlpha ran on its **own** Supabase project
(`hwxhigwaklzedxufwedv`) with its own 19-table schema. That project was
**deleted on 2026-08-12**. It is gone; there is no fallback to it.

GenAlpha is now a native tenant on `ugsklcipzyiogxynshnh`. Its old table
names survive as **views in a `genalpha` schema** over the shared tables:

| GenAlpha calls it | it really is |
|---|---|
| `students` | `members` + `genalpha.student_details` + `enrollments` |
| `student_payments` | `payments` |
| `attendance` | `sessions` + `attendance_records` |
| `academy_expenses` | `expenses` |
| `student_timeline` | `member_timeline` |
| `reminder_events` | `reminder_events` + `genalpha.reminder_event_details` |

**Every client must pin the schema or it gets a 404.** Web uses
`db: { schema: "genalpha" }`; Android sends `Accept-Profile` and
`Content-Profile: genalpha` from `baseRequest()`. A POST to `/rpc/`
routes on **Content-Profile**, so both headers go on every request.

The views are writable through `INSTEAD OF` triggers, and those triggers
are where 13 of the legacy project's 15 triggers now live — timeline
logging, fee-pause normalisation, WhatsApp contact sync, admission-claim
reconciliation. Do not "restore" a trigger that looks missing without
checking `students_write` / `student_payments_write` first.

## The trap that cost the most time

**There are two `reminder_events`.** `public.reminder_events` is the
shared table with 28 columns. `genalpha.reminder_events` is the view with
**all 49 legacy columns**, including `delivered_at`, `read_at`,
`accepted_at`, `failed_at`. The owner looks at the Table Editor, which
opens on `public` — so "the columns are missing" almost always means the
wrong schema is selected, not missing data. Switch the schema dropdown.

Do **not** solve this by copying those 38 columns onto the shared table.
It is a contract six academies sign, and `shared_widening_audit()` exists
to catch exactly that.

## Money

- Fees come from `genalpha.quote_fee(student_id, months)` — never from a
  client. `script.js` used to hardcode 3500/9975/18900 while **52 of 81
  students are on a different rate**.
- Payments go through `record_fee_payment()`, reached by inserting into
  the `genalpha.student_payments` view. Never insert into `payments`.
- Jersey is `kind='custom'` and must not buy coaching months.
- A duplicate-payment guard uses a 2-minute window on
  (member, kind, amount). An earlier cycle-based guard never fired,
  because each payment rolls `renewal_on` forward and makes the next tap
  look like a new cycle.

## WhatsApp — GenAlpha is the only tenant sending live

`config.whatsapp` is `enabled: true, dryRun: false, mode: auto`, sending
from its own number **+91 81439 60950** (`phone_number_id
1131427080050707`, `waba_id 896291036765497`, quality GREEN). The token
is in `vault.secrets` as `whatsapp:genalpha`.

- Reminders fire **09:30 UTC = 15:00 IST** (`genalpha-fee-reminders-daily`).
  `config.whatsapp.sendHourIST` is read into the config object and
  **never used to schedule anything** — the cron line is the only thing
  that sets the hour.
- Retry every 5 minutes; AgentAlpha intake sweep every 10 seconds.
- The engine is the edge function **`genalpha-whatsapp`**, not the
  platform's shared `whatsapp-reminder`. GenAlpha-only actions
  (`whatsapp_monthly_stats`, the UPI signals) exist only there. Calling
  the wrong one is why the WhatsApp Performance panel was blank.
- Delivery status is a **forward-only ladder** now
  (`advanceDeliveryStatus`). Meta callbacks arrive out of order, and the
  old code let a late `delivered` overwrite `payment_confirmed` — a
  money fact destroyed by a delivery receipt. Never assign `status`
  straight from a callback.

## AgentAlpha (admission intake)

`admission-intake` reads a WhatsApp conversation with the model and
drafts an admission. It depends on two things that are easy to break:

1. **`admission_intake_sessions.updated_at` is a concurrency token**, not
   bookkeeping. Every inbound message PATCHes the session and reads
   `updated_at` back as `debounceToken`. Three compare-and-swaps use
   `updated_at=eq.<token>`. The touch trigger that moves it was missing
   after the migration and was restored 2026-08-12l — without it the
   sweep reads half-typed conversations and can double-send.
2. **`admission_intake_messages(provider_message_id)` must stay UNIQUE.**
   The dedup branch is only reachable because the insert is rejected.
   Meta retries webhooks on any non-2xx.

## The Android app

`GenAlphaApp/android-app`, native Kotlin/Compose, currently **v1.0.64**.

Two access tiers, deliberately two separate fields:

| | roster + attendance | finance / editing |
|---|---|---|
| PIN (coach) | yes, contacts nulled by the DB | no |
| staff login | yes, contacts visible | yes |

- The PIN **is the password** of `coach@genalphaacademy.in`. It is not a
  string compared in Kotlin — that version fetched nothing, because the
  platform grants `genalpha.students` to `authenticated` only.
- `uiState.session` means STAFF. `uiState.coachSession` means coach.
  Collapsing them hid the login button and finance at the same time.
- The coach sees no phone numbers because `genalpha.students` NULLs them
  when `auth_role() = 'coach'` — the database decides, not the client.
- `pay.html` loads `assets/supabase-config.js`, which is **generated at
  build time** from `SupabaseConfig.kt`. Do not commit a static copy; a
  stale committed copy is what pointed at the dead project for months.

## Outstanding, GenAlpha-specific

- **Realtime is dead.** The `supabase_realtime` publication is empty, and
  the app subscribed to `public.students` etc., which do not exist here.
  A student is a view over four tables, so no row payload can rebuild
  one — realtime has to become a change *signal* plus a refetch. Half
  done in the repo; needs finishing and a decision about publishing
  shared tables for all six tenants.
- **No version gate.** v1.0.57–1.0.64 are in the field and cannot be told
  to update. `SupabaseConfig.kt` has the constant; nothing reads it.
- **Three fee engines still disagree** — `fee-plan-rules.js`, `Models.kt`,
  `payment_plans.ts`. House-rule violation; only the server side is
  fixed.
- **Manager password in plaintext `localStorage`** (`script.js` 538, 577,
  5732), read back to prefill the login.
- **UPI id `9059962499@ybl` is a client constant** in
  `supabase-config.js` while `resolve_upi()` exists to own that.
- **iOS never tested** for the pay.html UPI ordering fix.
- Five migrations (`2026-08-11b/c/d/kz/m`) are **on disk but gitignored** —
  they hold the original data dump with real phones and addresses. The
  ledger records them by basename + sha256, so never rename or move them.
