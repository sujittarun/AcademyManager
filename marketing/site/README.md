# academymanager — the public landing page

One self-contained page. No build step, no framework, no dependencies beyond
Google Fonts. Open `index.html` or serve the folder.

## Publishing it on a domain

The page is static, so any host works. On GitHub Pages:

1. Put this folder's contents at the root of a repo (or a `docs/` folder).
2. Settings → Pages → deploy from that branch.
3. Add the domain in Settings → Pages → Custom domain, and create a `CNAME`
   file here containing just the domain.
4. At the registrar, point an `ALIAS`/`ANAME` at `sujittarun.github.io`, or
   four `A` records at GitHub's Pages IPs.

**Do not publish it from the `AcademyManager` gh-pages branch.** That branch
serves the operator console and its file list is deliberately minimal; adding
marketing files there puts them on the same origin as the console.

## Two things it does that are not obvious

**It changes by region, with no API call and no cookie.** The browser's own
time zone already knows: `Asia/Kolkata` (or an Indian locale) shows ₹899
pricing and names WhatsApp; everywhere else shows a request-a-quote CTA and an
unnamed messaging channel. Nothing is sent anywhere, it works offline, and it
degrades to the international variant. Verified against Kolkata, Dubai and
London.

**Motion is opt-in, not opt-out.** The stylesheet hides nothing until the
script adds `html.anim`, so if JavaScript fails, is blocked, or the visitor
asked for reduced motion, the page is simply the finished page. The first
build did the opposite — `opacity:0` defaults with a reveal observer — and
every screenshot on the page rendered blank whenever the observer did not
fire. Animate from a visible default or do not animate.

## What is real, and what you must replace

Everything factual on the page is true as of 2026-08-25 and was read from the
platform database, not estimated:

| Claim | Source |
|---|---|
| 6 academies running on it | `tenants`, excluding the demo tenant and archived MatchPoint |
| 5 sports, plus a music school | `select count(distinct sport) from batches` |
| 5,700 registers marked | `attendance_records` |
| 564 payments recorded | `payments` |
| ₹899 a month | Mezzo's actual subscription |

**Re-check these before a campaign** — a number that has drifted is worse than
no number. There are no testimonials, no logos-of-companies-you-do-not-have,
and no invented customer counts; the gallery is the proof.

`academymanager@outlook.in` is the live contact address, set 2026-08-25. It
appears in four places on the page.

## The eight academy screenshots

All eight are public marketing sites, so showing them publishes nothing new.
The interior screens (dashboard, members, attendance, finance, renewals) are
the **demo tenant only**, and deliberately: those render live Postgres, and a
real academy's revenue and student roster are their commercial information,
not our marketing material. Keep it that way if you re-shoot.

Re-shoot with the capture script used to build them — 1440×900 at
`--force-device-scale-factor=2`, then `magick … -resize 1440x -quality 82` to
webp. The whole image set is 655 KB.
