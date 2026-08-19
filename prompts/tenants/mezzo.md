# Mezzo School of Music — paste into a chat opened in `Mezzo/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-19**.

`mezzo` — the platform's **first paying client**. Music school on
Thadagam Road, Coimbatore. Dr. R. Santhana Krishnan, Director & Tutor.

## The one thing that shapes every decision

**He is the only user, and he is not a technical person.** No front desk,
no second operator to catch a mistake, no appetite for a screen that
needs explaining. Before adding any control, say what it replaces —
"it's only one more button" is how this becomes an app he stops opening.

Three tabs, always visible, nothing nested. Nothing under 15px. Every
tappable thing at least 48px: a mis-tap on a register marks a child
absent.

## Shape

| | |
|---|---|
| ~95 enrolled, ~80 active | one teacher, all eight instruments |
| Mon–Fri 15:00–20:00 IST | batch `weekday` |
| Sat 10:00–20:00 IST | batch `saturday` |
| Piano **₹2,500** | `fee_rules` sport rung |
| Everything else **₹1,500** | `fee_rules` tenant-default rung |

**Batches are the time window, not the instrument.** One batch per
instrument would need sixteen of them to carry two day patterns, and
would make him pick an instrument before he can mark a register. The
instrument rides on `enrollments.sport`, which is where the fee chain
reads it anyway.

**Instruments are `sports` rows.** Same noun, different word.

**Flute is seeded `active = false`** — struck through by hand on the card
he handed over, which reads as withdrawn rather than a printing error.
Ask before turning it back on; do not assume either way.

## Reminders are deliberately not a ladder

`config.reminders = {mode:'simple', afterDays:1}`, read by the shared
`reminder_queue()` (`2026-08-19r`). One nudge, one day late, every day
until paid. **No +15 stop** — that rung exists to end an escalation, and
this rule never escalates.

**Never filter the dues list in the app.** What comes back IS the list.
Filtering in the client is how his screen and his WhatsApp message start
disagreeing about what a family owes.

## What was added to the platform for this tenant

| | |
|---|---|
| `2026-08-19q` | the tenant, centre, 8 instruments, 2 batches, 2 fee rules |
| `2026-08-19r` | `reminder_queue()` reads `config.reminders`; every other tenant's queue verified byte-identical before and after |
| `2026-08-19s` | `attendance_month()` — the monthly register in one call. Neither `attendance_roster()` (one day) nor `attendance_history()` (per session) builds a grid |
| `2026-08-19t` | six sample students, `is_demo = true` |

**Clearing the sample data on go-live is one delete:**

```sql
delete from members where tenant_id = 'mezzo' and is_demo;
```

## Two things that bit during the build

1. **`mark_attendance(…, null)` CLEARS a mark.** The adapter had
   `p_status: status || "present"`, which turned an intentional clear
   back into a present — the third tap of the register's cycle would
   have silently done nothing forever. Do not reintroduce that default.
2. **The class-day filter needs reference data that arrives on a second
   request.** Without a re-render when it lands, the register sits on its
   safe fallback (show everybody) and looks broken while being correct
   about what it knew. Found in a browser, not by the harness.

## Before committing anything in that repo

```bash
node scripts/check-app.js
```

It runs the real app in node and asserts on the HTTP calls, not the
markup. It has already caught a call to an adapter function that did not
exist, and the `|| "present"` bug above.
