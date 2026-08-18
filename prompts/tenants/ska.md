# Super Kings Academy — paste into a chat opened in `SuperKingsAcademy/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-18**.

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
| Coaching | cricket | Morning + Evening batches, the shared fee chain |
| 2 astro nets | `astro`, courts A1 A2 | ₹500/hour |
| 2 matting nets | `matting`, courts M1 M2 | ₹400/hour |
| 1 main ground | `ground`, court G1 | **full day only**, by weekday |

Ground: **Mon–Thu ₹10,000 · Fri ₹20,000 · Sat–Sun ₹25,000.**

The nets were ONE pool until 2026-08-18, with the surface as a label —
that was the client's call and it was right until they priced the two
apart. `2026-08-18c` split them, exactly as `2026-08-17b`'s header said
would be required. `G1` is never shown to a user: it is derived, there is
only one ground, and the screens say "Main Ground".

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

## The mobile pass, 2026-08-18 — what it found

Tested at 375×812 on the live site, signed in as a throwaway staff account.
Layout held everywhere: no horizontal scroll, no clipped text, the wide
ledger tables scroll inside their own `.table-wrap`. Four real faults, all
fixed and verified:

**1. Native dialogs do not work, and four operator actions did nothing.**
Measured in the app's own browser: `window.prompt(...)` **throws**
`prompt() is not supported.` and `window.confirm(...)` **returns false
without showing anything**. A throw kills the handler; a false reads as
"the operator said no". So on a phone: declining a booking, approving an
admission, declining an admission and "mark the rest present" all did
nothing — three of them silently, no toast, no error, the row just sat
there.

`bookings.html` already knew — its comment says "window.prompt is
suppressed on iOS" and it built a reason sheet for the cancel path. The
other five call sites never got converted.

`LT.ask()` is now in `core.js`: an in-app confirm and an in-app prompt in
one, resolving to a **string** when confirmed and **null** when dismissed,
so it drops into a `if (x === null) return;` prompt site unchanged. Use it.
Never reach for `window.confirm` or `window.prompt` in a tenant app again.

**The same bug is still live in other repos** (not touched — different
repo, different session): `LeoTennis` 2 call sites, `MatchPoint` 1,
`GenAlpha` 4, and the **operator console** 6. Nothing dangerous happens —
they all fail closed — but the operator simply cannot complete those
actions. `AcademyManager/index.html:1617` is a type-to-confirm delete, so
that one is blocked rather than broken.

**2. `LT.ask` itself shipped broken for ten minutes** — it opened with a
double `requestAnimationFrame`, and rAF does not fire in a hidden or
backgrounded tab, so the sheet was appended and never shown. Now it forces
layout with `void back.offsetHeight` and opens in the same tick. The reveal
and count-up observers already carry this lesson; it is three for three.

**3. Every stat animated twice on every load.** A page that fetched its
data called `LT.countUp` directly, and core's 1200 ms safety net then found
the element unvisited and counted it from zero again. A direct call now
sets `el._cuDone` and retires the net. Reported on "Collected today"; it
was every stat on every page.

**4. Light mode had no edges.** Every border was white — the dark theme's
specular rim, never re-derived — measuring **1.06:1** against the `#f2f3f7`
page. Now dark ink hairlines at 1.32–1.50:1 with the white kept as the
inset top highlight, which is what a glass edge actually is. Compact
controls were also 31px tall on a phone; they are 40 now.

## Outstanding

- **The UPI handle is PROVISIONAL.** `9585491000@ybl`, supplied with the
  words "i am not sure if this is correct". Send ₹1 and check the payee
  name the app shows BEFORE the academy takes real money. It is one
  UPDATE to `config.billing.upiIds`, and `resolve_upi()` is the only
  thing that reads it.
- **Fee rules are placeholders**: Morning ₹2,500, Evening ₹3,000,
  admission ₹1,000. The client had deferred fees; these were added to
  test the chase ladder and are labelled as placeholders in `note`.
  Confirm the real amounts.
- **Scenario test data is still in the database.** Five demo members
  (`members.is_demo`), a week of bookings on synthetic 90000 phones, and
  a maintenance block. Remove with
  `SuperKingsAcademy/supabase/REMOVE-TEST-DATA.sql` before go-live.
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
`upper(left(sport,1)) || i`. `astro`→A, `matting`→M, `ground`→G. Adding a
facility type starting with A, M or G collides silently and presents as a
booking landing on the wrong court.
