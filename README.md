# Academy Manager — Control Room

Operator console for the Academy Manager platform: every client academy
(Leo Tennis Academy, Gen Alpha Cricket Academy, …) monitored from one
screen — bookings, revenue, coaching enquiries, payments, reminders and
app-usage analytics, per tenant.

- **Data**: the multi-tenant Supabase project (org *Academy Manager* ·
  project *Leo Academy*); schema lives in the Leo repo under
  `supabase/schema.sql`. Every table carries `tenant_id`.
- **Stack**: vanilla HTML/CSS/JS, no build step. `assets/css/am.css` is
  the platform design system (liquid glass, navy + violet + gold).
- **Deploy**: push to `main` (GitHub Pages).

Client apps feed this console through their `LT_CLOUD` adapters — see
`assets/js/cloud.js` in each academy repo.
