# Super Kings Academy — paste into a chat opened in `SuperKingsAcademy/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-17**.

`ska` — a CSK-affiliated **cricket academy AND facility-rental business**
in Coimbatore. Both revenue lines at once, which is what makes it
different from every other tenant: Raj is coaching-only, Leo is
venue-only, `ska` is both.

## Why this one is different from the others

**It is the first client who has actually committed to using the
platform.** Go-live **2026-09-01**. Everything else on the platform is a
pilot, a demo, or a tenant that has not started. So `ska` is the first
tenant where a bug costs a real academy real money on a real morning,
and the first whose data must be loaded to a deadline.

Commercially it is a **two-month trial on ONE venue**. They run two; the
second is onboarded only if the first lands. That is why there is exactly
one `centres` row — the second venue is a future INSERT, not a config
edit.

## The venue name

**`VAKAMAN FE`, all capitals.** Not "Vakaman FE", not title case. It
matches their own Google listing ("Super Kings Academy Coimbatore (SKA
Coimbatore) | Vakaman FE") and the client writes it that way.

## What they sell, and how it is priced

| | | |
|---|---|---|
| Coaching | cricket | members / enrollments / batches, the shared fee chain |
| 4 practice nets | `nets`, courts N1–N4 | ₹500/hour, flat |
| 1 main ground | `ground`, court G1 | **full day only**, by weekday |

Ground: **Mon–Thu ₹10,000 · Fri ₹20,000 · Sat–Sun ₹25,000.**

The 4 nets are **one pool**, deliberately — 2 Astro and 2 Matting, but
the client asked for the surface to be a label, not a pricing axis.
`config.courtLabels` maps `N1`→`Astro Net 1` … `N4`→`Matting Net 2`. If
Astro is ever priced above Matting they must become separate facility
types, which is a migration, not a config edit.

## The three things to know before touching anything

1. **`slot_rate()` cannot price this tenant's ground, and must not be
   made to.** It takes no date, so it cannot know the weekday.
   `slot_price(p_tenant, p_sport, p_date, p_hour)` (migration
   `2026-08-17c`) adds the date axis and **delegates to `slot_rate()`
   whenever the facility has no `daily` block** — so Leo, MatchPoint and
   the demo price exactly as before, by construction rather than by
   testing. Do not "simplify" that delegation away.

2. **A full-day booking is `hour = 0`, forced server-side.** `bookings`
   has `CHECK (hour between 0 and 23)` so there is no sentinel room, and
   `bookings_slot_unique` is on `(tenant_id, date, hour, court)`. Forcing
   hour 0 inside `record_booking_v2()` is what makes that existing index
   stop the ground being sold twice for one day. If the client were
   trusted to send hour 0, an operator entering 14:00 would not collide
   and the ground would be double-sold. It is a guarantee, not a
   convention — `supabase/tests/2026-08-17c-*.sql` asserts it.

3. **Rental collection lives on the booking, NOT in `payments`.**
   `tenant_revenue_streams()` already sums `bookings.amount` for rental
   revenue and reads `payments` only for `type='Membership'`, so a
   payments row per booking is the same rupee counted twice. Collection
   is `bookings.paid_at` / `paid_mode` / `collected_by`.

## The fee-rule trap, found by testing on 2026-08-18

**A fee rule keyed on `sport` will never match at this academy, and will
fail silently.**

The admission form does not ask which sport — it is a cricket academy, so
nobody thought to. `submit_application` therefore stores `sport = null`,
`approve_application` copies that into `enrollments.sport`, and
`resolve_fee`'s chain looks for a rule matching that null. A rule created
with `sport = 'cricket'` is skipped, `resolve_fee` returns
`source: 'unset'`, and every member sits at `blocked_reason: fee_not_set`
for ever. Nothing errors. The queue simply never chases anyone.

Proven both ways on the same enrolment:

```
resolve_fee(..., sport => enrolment's null, ...)  -> unset
resolve_fee(..., sport => 'cricket',        ...)  -> 2500, source 'batch'
```

**So: key SKA's fee rules on the BATCH and leave `sport` null.** A
batch-keyed rule matches regardless of the enrolment's sport, which is
what the two live rules do. If a sport-keyed rule is ever wanted, the
enrolment has to carry a sport first — that is a change to the admission
form and to `approve_application`, not to the rule.

## Outstanding

- **`tenant_revenue_streams()` is hardcoded to `sport='tennis'` and
  `'pickleball'`** and therefore returns ₹0 for `nets` and `ground`. It
  is blind to this tenant. The Finance screen cannot be honest until it
  is made config-driven — and doing so must not change the JSON keys the
  demo's donut renders.
- **No UPI collection id yet.** `config.billing.upiIds` is `[]` on
  purpose. `resolve_upi()` falls back to `upiIds->>0`, so fee collection
  has no destination until the client supplies the real one. Never invent
  a plausible handle.
- **WhatsApp is sold but not provisioned.** `modules.whatsapp` is `true`,
  `config.whatsapp.enabled` is `false`, `dryRun` `true`. A tenant with
  WhatsApp enabled and no number does not fail loudly — it queues
  reminders that never send. Flip `enabled` only when the Business number
  exists.
- **The app repo is PUBLIC**: `github.com/sujittarun/SKAcademy`. The anon
  key belongs there; nothing else does. No credential, no `service_role`,
  no real member name or parent phone — history keeps what you delete.
- Facial-recognition attendance is a **future** ask, explicitly parked
  until the basics are live. Do not build toward it yet.
- Player progression is **not** sold — `features.playerTracking` is
  `false`. Do not copy MatchPoint's 11-table cluster in.

## Watch the first-letter rule

`record_booking()` and `record_booking_v2()` derive the court id as
`upper(left(sport,1)) || i`. `nets`→N, `ground`→G. Adding a facility
type starting with N or G collides silently and presents as a booking
landing on the wrong court.
