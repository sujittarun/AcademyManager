# The arm-B attachment: how to make it, and why it's this screen

Arm B of the opener test sends the text plus **one** image. This is that
image.

---

## Shoot the DASHBOARD, not the Finance screen

The plan was the dues screen on `fees.html`. **Do not use it.** Checked on
2026-08-12, that page renders:

```
Collected · last 30 days   ₹5,270  across 9 payments
Net margin · Jun           5%      ₹637k profit
Revenue vs expenses        bars on a ₹1,315k scale
```

Those are the `assets/js/data.js` seed numbers, and they contradict each
other on the same screen — ₹5,270 collected next to ₹637k profit. The demo
repo's own CLAUDE.md says it outright: *"do not demo the fees or reminders
screens"*, because that page derives from the local seed rather than
Postgres. Sending it would hand a prospect proof that our numbers do not
add up, which is the opposite of the pitch.

The **dashboard** is wired to `demo_snapshot()` and every figure on it is
real and mutually consistent. That is what to send.

## Making it

```bash
node AcademyManager/scripts/shoot-arm-b.js
```

Writes `marketing/leads/dashboard-dues.png` at 2x, so it stays crisp on a
phone. Ten seconds, and it is the reason this is a script rather than a
`Cmd+Shift+4`: the figures drift (see below), and a stale asset is worse
than none.

It **refuses to save a bad asset** rather than producing one quietly:

| It stops if | Because |
|---|---|
| `demo_snapshot()` returns nothing | a blank dashboard is not a demo |
| `source` is not `postgres` | the numbers would be the JS seed |
| `active_members <= 16` | that IS the JS seed — the exact understatement this replaced |
| dues are zero | there is no pain to show |
| a 10-digit number appears on screen | never send a phone number to a prospect |

It also freezes the count-up animation before shooting. The dashboard
animates its KPIs on load, and a capture taken mid-animation showed "23"
where the real figure is 94 — the understatement, reintroduced by the
screenshot of the fix.

Playwright lives in the session scratchpad, not in the repo, so nothing was
added to `package.json`. If `node` cannot find it:

```bash
NODE_PATH=<scratchpad>/shotter/node_modules node AcademyManager/scripts/shoot-arm-b.js
```

## Three sizes, and which to send

| file | size | use |
|---|---|---|
| `dashboard-dues-whatsapp.jpg` | 1600px, ~130KB | **send this one.** WhatsApp recompresses to roughly this anyway; starting smaller means it uploads instantly on mobile data |
| `dashboard-dues.png` | 2000px, ~340KB | decks, docs, email |
| `dashboard-dues-4k.png` | 3816px, ~4.2MB | the master. Do not attach it to a chat |

## What the shot should show

Verified live on 2026-08-12:

| | |
|---|---|
| Active members | **94** |
| Court bookings today | varies (live) |
| **Renewals due** | **30 · worth ₹92,800** |
| Revenue · August | ₹90k · Jul closed at ₹91k |
| Renewal status | **68% paid up · 64 paid up / 30 due** |

The frame is fitted to the app's content width rather than a fixed 1920 —
at 1920 the layout centres itself and leaves ~600px of empty gradient each
side, which on a phone shrinks the numbers to nothing. The script measures
the container and scales to reach ~4K.

It stops above "Recent activity": that section and a `₹9,975` figure below
the donut come from `LT_DATA`, not `demo_snapshot()`, and the feed prints
member names. Mixing real and seed numbers in one image is the Finance-page
mistake in miniature. The cut is measured from the DOM, so a layout change
cannot pull it into frame.

"Renewals due 30 · worth ₹92,800" is the line that does the work — it is
the pain the opener just asked about, and the amount comes from
`reminder_queue()`, the same function that decides what a parent's
WhatsApp message says.

## It carries no personal data — keep it that way

The dashboard shows counts and amounts only: **no member names, no phone
numbers**. That is deliberate — `demo_snapshot()` returns none, and it is
asserted in `2026-08-12za`.

So do **not** substitute a Members or Attendance screenshot. Those show the
roster, and while the demo names are synthetic, four of them collide with
real academies' members, and every phone on the demo is the owner's own
number — thirty rows of the identical number is also a detail a prospect
would notice.

## This goes stale — re-run it monthly

`demo_reset('roll')` moves the demo calendar nightly and
`demo_spread_payments()` redistributes the payment history, so the figures
drift. A screenshot claiming August when it is October reads as a dead
product. Re-run the script at the start of each month, or whenever
`demo_reset('rebuild')` has been run.

To check the numbers without opening a browser:

```bash
curl -s -X POST "https://ugsklcipzyiogxynshnh.supabase.co/rest/v1/rpc/demo_snapshot" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{}'
```

## Sending it

`wa.me` carries text only, so the image is attached by hand in the
WhatsApp Business app: send the opener first, then the image as a second
message in the same thread. Text first matters — the notification preview
is the text, and that is what they actually read.

**One image, not two.** One is a hook; two is a brochure and invites them
to evaluate without replying. The flyer and the demo link belong in the
reply, not here.
