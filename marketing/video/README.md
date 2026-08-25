# The international product video

`academy-manager-international-90s.mp4` — 90s, 1920×1080, silent with
on-screen captions. Cut for prospects **outside India**.

Re-runnable. Nothing here is hand-edited footage: every frame is recorded
from the live demo app, so re-rendering after a UI change is two commands.

**The .mp4 files are NOT in git, on purpose.** The repo's `.gitignore` excludes
rendered media because 1.6 GB of mp4/webm/wav once lived in this history, and
this output is regenerable by definition — that is what the pipeline is for.
The rendered file sits untracked next to this README:

    marketing/video/academy-manager-international-90s.mp4   (16 MB, 90.0s)
    marketing/video/cards/opener.mp4                        (1 MB, the paid 5s)

`cards/opener.mp4` is the one piece that is **not** free to regenerate — it cost
32.5 Seedance credits. Keep a copy somewhere durable (a Release asset or Drive)
before wiping a working tree, or the next render either loses the opener or
spends the credits again.

```bash
cd <a folder with playwright installed>          # see "Dependencies"
node   record.js        # records 9 shots -> /tmp/vid/shots/*.webm
python3 assemble.py     # trims, crossfades, encodes the mp4
```

## Why this cut exists, and what is deliberately absent

Three things in the India product do not travel, and all three are handled
by `localise.js`, which rewrites the DOM **at record time**:

| In the app | In this video | Why |
|---|---|---|
| `₹` | `AED ` | — |
| WhatsApp | "Parent alerts" | The owner's call: markets like the UAE get an unnamed channel rather than a named one. |
| Bengaluru / Hyderabad, `+91`, Indian localities | Dubai, `+971`, Al Quoz / Dubai Sports City / Jumeirah | A Dubai prospect seeing another country's STD code stops watching. |

**The currency is a symbol swap with the figures left alone, on purpose.**
Converting ₹52,380 lands at ~AED 2,300 for 94 members, which is implausibly
cheap for Dubai. Left as AED 52,380 it works out at about **AED 557 per
member per month** — in-market. The data is fictitious either way; the only
thing that matters is that it is believable to the person watching.

**No booking aggregators appear.** Playo, Hudle and District do not exist in
these markets, and they live in CourtSync, which is off unless a tenant buys
`config.modules.booking`. The app's own court-booking tile is still on screen
— that is scheduling, not an integration.

## What it does NOT fix

`localise.js` runs in the recording, **not in the app**. A prospect who opens
the demo link still sees ₹, `+91` and Bengaluru. The video will land better
than the live link does, and the real fix is a locale-aware demo reading
currency and city from tenant config. Do that before sending links to UAE
prospects.

## No credentials, by construction

All seven pages across the three tenant apps were probed: **zero password
fields**. Everything recorded here renders publicly. That is load-bearing —
a demo that needed a login could not have been recorded at all.

## Names on screen are safe to publish

This repo is public and the footage shows a member roster, so the names were
checked rather than assumed. Every visible name comes from the demo's
verified-clean fixture set, and a query against `members` confirmed **none of
them belongs to a real tenant**. Re-run that check if the demo dataset
changes — `AcademyManagerDemo` shipped five real members' names once already.

## Dependencies

- `playwright` + a real Chrome (`channel: "chrome"`). The cached Playwright
  Chromium was the wrong build, hence the system channel.
- `ffmpeg` with `libx264`. This build has **no `drawtext`** (no libfreetype),
  which is why every caption and card is rendered in the browser instead of
  burned on afterwards — better anyway, since it picks up the product's own
  typeface and a real backdrop blur.
- The opening 5s is AI-generated (Seedance, 16:9, 32.5 credits) and is kept
  as `cards/opener.mp4` so a re-render does not re-spend credits.

## Shot list

| # | Shot | Caption |
|---|---|---|
| 0 | cinematic opener | — |
| 1 | title card | Run the academy, not the spreadsheet |
| 2 | branded parent site | Parents see your academy — not a spreadsheet, not a group chat |
| 3 | dashboard | Members, renewals and revenue across every venue, live |
| 4 | members & batches | Every student, their batch, their coach, their standing |
| 5 | attendance | Mark a whole batch in seconds — from the court, on a phone |
| 6 | fees & renewals | See exactly who has paid, who is due, and what it is worth |
| 7 | parent alerts | Renewal due? Parents are messaged before it lapses — no chasing |
| 8 | end card | Your academy. Your brand. Your own app. |
