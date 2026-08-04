# Flyer accuracy audit — 2026-08-04

Every claim on the previous flyer was checked against the codebase before
this version was written. Ten claims did not survive. They are recorded
here because each one would have become a broken promise in a sales
meeting, and because the same mistakes are easy to re-introduce.

## Removed — the product does not do this

| Old claim | What is actually true |
|---|---|
| **"Parent/Student" access layer** — make payments, view attendance history, track student progress | **No parent or student login exists anywhere.** `auth_role()` only ever returns `operator`, `staff` or `coach`. There is no parent role, no parent session, no parent-readable policy, and no self-service sign-up in any tenant app. `pay.html` is a static, unauthenticated UPI QR page driven by URL parameters — it records nothing and shows no attendance or progress. This was a whole access layer plus two matrix rows describing software that has not been written. |
| **"Payment collection: Full payments"** and **"online payment processing charges"** | **There is no payment gateway** — no Razorpay, Cashfree, Stripe, PayU or Paytm anywhere in any repo. Collection is a UPI deep link with the amount pre-filled, plus a screenshot proof and a staff confirmation. This is now sold as the advantage it genuinely is: money goes straight to the academy's own account, with no gateway cut. |
| **"Coach/Staff"** — view players, edit player details, manage batches, send reminders | **Backwards on four of five.** The `coach` role is attendance-only by deliberate design (migration `0039`), scoped to assigned centres, and passes no RLS policy — it cannot see fees, dues or a parent's phone number. The role that *can* do those four things is `staff`, which is the same login as Owner/Admin and sees all the money. There is no reduced-admin tier. |
| **"Reports & insights"** | No CSV, Excel or PDF export exists in any tenant app. Renamed to **Insights**, which is what ships. |
| **"Branding included" only at Pro**, plus a ₹4,999 branding add-on | Backwards, in the customer's favour. **Every** academy already gets its own repo, theme, logo and web address at any tier — a Starter customer has nothing to be upgraded from. Branding moved to the top of the flyer as the lead differentiator; the ₹4,999 add-on now covers genuine identity/design work only. |
| **"Native Android & iPhone staff apps"** | Android exists but ships as a direct install, not Google Play. **iOS cannot be given to anyone** until an Apple Developer Program account exists. iPhone was removed from the flyer entirely rather than promised. |
| **"Data migration & bulk import"** as tooling | No importer exists; the one attempt was deleted for reporting success while importing nothing. Reworded to what is genuinely delivered: we move the list across **by hand** during onboarding. |

## Reworded — true, but it oversold or undersold

- **WhatsApp "Manual / Semi-automated / Automated" per tier.** Only two
  modes exist in code (`manual` | `auto`), and **automatic sending has
  never run for a live academy** — every reminder on the platform to date
  is a manual send. The flyer now says reminders send with one tap from
  day one, and automatic daily sending switches on once the academy's own
  WhatsApp Business number and templates are approved.
- **"Manual" as the entry-level cell undersold the product badly.** It
  does not mean typing messages: the system builds the due list, resolves
  the amount through the seven-level fee chain, resolves which UPI account
  that centre collects to, and writes the message. The ladder (−2 days,
  due date, +5, daily to +14, stop at +15) is now stated on the flyer,
  because it is a genuine differentiator.
- **"Complete management app."** No single client today does all eight
  nouns in the old headline. Dropped "complete" — it buys nothing and
  costs credibility.

## The structural finding

**No per-plan feature gating exists in the product.** `subscriptions.tier`
and `player_cap` are informational columns the operator console displays;
nothing in any tenant app or SQL function reads them to switch a feature
on or off. Nothing blocks a 51st student, and staff seats are not metered
at all.

So the old matrix — Basic/Advanced/Full finance, tiered coach access,
tiered reports — described gates that do not exist. Rather than invent
them, the flyer now tiers on three things that are real:

1. **Scale** — active students, coach logins, single vs multi-centre.
2. **Modules** — booking + channel sync, and player development. These are
   genuinely optional (`config.modules.booking` is a real per-tenant flag).
3. **Service** — onboarding depth and support priority.

Everything else is marked included on every plan, which is both honest and
a stronger pitch: *the manager is never cut down; you pay for the size of
your academy.*

## Before the flyer goes to a prospect

- Demo **Raj Sports** or **MatchPoint Pride**, not Leo or Machaxi — only
  the first two are wired to the platform's fee/reminder engine.
- If demoing MatchPoint Pride, do not open on attendance: it currently has
  staff attendance only, not student attendance.
- If the prospect is a court/turf venue rather than a coaching academy,
  the attendance model (student belongs to a batch with a register) needs
  explaining up front.
