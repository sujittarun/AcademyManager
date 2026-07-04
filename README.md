# Academy Manager — Operator Console

The platform owner's console: every client academy (Leo Tennis Academy,
Gen Alpha Cricket Academy, …) as an **account**, tracked the way a
professionally run SaaS tracks its book of business.

**What it shows (account level only):**
- MRR per subscription and company rollup (`subscriptions` table)
- GMV flowing through each academy's app (bookings + payments, 30d, with
  trend vs the prior month and weekly bars)
- Adoption health — last active, active days, sessions; Active / Quiet /
  At-risk / Onboarding status per account
- Growth signals — bookings and coaching-enquiry counts, channel mix

**What it deliberately does NOT show:** members, phone numbers, schedules,
individual payments. Operational data stays in each academy's own console.

- **Design**: paper-and-ink ops dashboard (`assets/css/console.css`) —
  flat, hairline rules, tabular numbers, single indigo accent. Intentionally
  unrelated to the liquid-glass tenant apps.
- **Data**: the multi-tenant Supabase project (org *Academy Manager*);
  schema in the Leo repo under `supabase/schema.sql`.
- **Stack**: vanilla HTML/CSS/JS, no build step. Deploy = push to `main`.
