# Demo — paste into a chat opened in `AcademyManagerDemo/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-19**.

`demo` — the public sales demo. **The id is `demo`, not `demo-courts`.**

**Three names, on purpose.** `tenants.name` is **"Demo Sports Academy"**
since `2026-08-19m` — that is the operator console's label, and it says
"Demo" because the demo stays visible on the dashboard rather than
hidden (`0012`), so it has to be legible as a demo from the name alone.
`config.brand` is "Crescent Sports Academy". The app's own title is
"Sports Academy" and is left that way deliberately: it is shown to
prospects, and the word "Demo" belongs on the operator's screen, not in
the product being demonstrated. If you are about to make these agree,
read this paragraph again first.

## State

94 synthetic members, 94 enrollments, 225 payments, 464 bookings.
Booking module **on**, public timetable **on** — anon sees 2 centres,
8 batches, 2 sports, which `anon_probe()` asserts.

## What matters here

- **Every row is synthetic.** It is the one tenant where you may seed,
  reset and break things freely. `demo-roll-nightly` rolls the data
  forward at 20:30 UTC so the demo never looks stale.
- **It must not pollute business totals.** The demo is counted in the
  subscription list, so any MRR/GMV it carries lands in the operator's
  numbers. Verify that before quoting a revenue figure.
- It is the only tenant with the booking module genuinely on, so it is
  the natural place to exercise CourtSync changes.

## Outstanding

- Confirm the demo is excluded from MRR/GMV in the console.
- Publishing the demo repo and its Pages site was started, not finished.
