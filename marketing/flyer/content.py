# Flyer copy. Every claim here was checked against the codebase on
# 2026-08-04 (see AUDIT-NOTES.md). Two rules for editing:
#   1. If it is not built, it does not go on the flyer.
#   2. Do not tier a feature the product does not actually gate. Nothing
#      in the platform reads subscriptions.tier to switch a feature on or
#      off, so the tiers sell SCALE, MODULES and SERVICE — never a
#      cut-down manager.

CONTENT = {
"PITCH": "Your academy gets <b>its own branded app</b> — not a login on someone else's dashboard. "
         "Students, batches, attendance, fees and WhatsApp reminders, run from your phone.",

"CAPS_TITLE": "What your academy runs on",
"CAPS_SUB": "included on every plan — no spreadsheets, no WhatsApp groups to chase",
"CAPS": "".join([
 ('<div class="cap"><div class="ico">◉</div><h3>Your own app</h3>'
  '<p>Your name, your colours, your logo, your web address. Staff sign in to your academy, not a shared product.</p></div>'),
 ('<div class="cap"><div class="ico">✓</div><h3>Attendance</h3>'
  '<p>Take the register courtside in seconds. Per-batch history, attendance rates and per-student standing.</p></div>'),
 ('<div class="cap"><div class="ico">₹</div><h3>Fees that price themselves</h3>'
  '<p>Seven levels of fee rules — student, batch, centre or sport. Nobody is ever quoted the wrong amount.</p></div>'),
 ('<div class="cap"><div class="ico">✆</div><h3>Reminders on a fixed ladder</h3>'
  '<p>A heads-up 2 days before, a nudge on the due date, then day 5 and daily to day 14 — then it stops and hands you a call list.</p></div>'),
 ('<div class="cap"><div class="ico">⇄</div><h3>UPI straight to you</h3>'
  '<p>The reminder carries a link with the amount pre-filled, paid into your own UPI account. No gateway, no cut.</p></div>'),
 ('<div class="cap"><div class="ico">▤</div><h3>Money that reconciles</h3>'
  '<p>Confirm a payment once: the renewal rolls forward, the dues list updates and the reminder closes together.</p></div>'),
 ('<div class="cap"><div class="ico">✎</div><h3>Admissions</h3>'
  '<p>A public enquiry form that lands in your console, ready to approve straight into a batch.</p></div>'),
 ('<div class="cap"><div class="ico">▦</div><h3>Insights</h3>'
  '<p>Collections by month and centre, attendance trends, absence streaks and every student&rsquo;s payment history.</p></div>'),
]),

"LAYERS_SUB": "two logins &mdash; and parents need none at all",
"LAYERS": "".join([
 ('<div class="layer"><div class="lh">Owner / Manager</div><ul>'
  '<li>The whole academy: students, batches, centres, coaches</li>'
  '<li>Finance &mdash; collections, dues, expenses, historical income</li>'
  '<li>Fee rules, and which account each centre collects to</li>'
  '<li>Send reminders and confirm payments</li>'
  '<li>Centre &amp; coach revenue share</li></ul></div>'),
 ('<div class="layer"><div class="lh">Coach &mdash; register only</div><ul>'
  '<li>Sees only the batches at the centres you assign</li>'
  '<li>Takes the register; reviews that batch&rsquo;s history</li>'
  '<li>Never sees fees, dues or a parent&rsquo;s phone number</li>'
  '<li>Enforced in the database, not hidden in the screen</li>'
  '<li>Hand over the register without handing over the academy</li></ul></div>'),
 ('<div class="layer"><div class="lh">Parents &amp; students</div><ul>'
  '<li>Nothing to install, no password to remember</li>'
  '<li>Fee reminder on WhatsApp with the exact amount</li>'
  '<li>One tap opens UPI with your account pre-filled</li>'
  '<li>They send the screenshot; it is stored on the payment</li>'
  '<li>Apply to join through your admission form</li></ul></div>'),
]),

"PRICE_SUB": "every plan is the full product &mdash; you pay for the size of your academy &middot; GST extra",
"TIERS": "".join([
 '<div class="tier"><h3>Starter</h3><div class="cap-line">up to 50 active students</div>'
 '<div class="price">&#8377;899<small>/mo</small></div><div class="yr">or &#8377;8,999 / year</div>'
 '<div class="save">2 months free</div></div>',
 '<div class="tier pop"><div class="flag">MOST POPULAR</div><h3>Growth</h3><div class="cap-line">up to 100 active students</div>'
 '<div class="price">&#8377;1,999<small>/mo</small></div><div class="yr">or &#8377;19,999 / year</div>'
 '<div class="save">2 months free</div></div>',
 '<div class="tier"><h3>Pro</h3><div class="cap-line">up to 150 active students</div>'
 '<div class="price">&#8377;3,999<small>/mo</small></div><div class="yr">or &#8377;39,999 / year</div>'
 '<div class="save">2 months free</div></div>',
 '<div class="tier ent"><h3>Enterprise</h3><div class="cap-line">150+ students, chains &amp; multi-venue</div>'
 '<div class="price">Custom</div><div class="yr">built around your operation</div></div>',
]),

"MATRIX_SUB": "the manager is never cut down &mdash; plans differ by scale, modules and service",
"MATRIX_ROWS": [
 ("Active students included",                 ["50", "100", "150", "Custom"]),
 ("The full manager &mdash; students, batches, attendance, fees, dues, insights",
                                              ["Yes", "Yes", "Yes", "Yes"]),
 ("Your own branded app &amp; web address",   ["Yes", "Yes", "Yes", "Yes"]),
 ("WhatsApp fee reminders",                   ["Yes", "Yes", "Yes", "Yes"]),
 ("UPI collection with payment proof",        ["Yes", "Yes", "Yes", "Yes"]),
 ("Admissions &amp; enquiries",               ["Yes", "Yes", "Yes", "Yes"]),
 ("Register-only coach logins",               ["2", "5", "10", "Unlimited"]),
 ("Multi-centre / multi-venue",               ["1 centre", "Yes", "Yes", "Yes"]),
 ("Court booking &amp; slot board <i>(module)</i>",
                                              ["&mdash;", "Add-on", "Included", "Included"]),
 ("Channel sync &mdash; Playo &middot; Hudle <i>(module)</i>",
                                              ["&mdash;", "Add-on", "Included", "Included"]),
 ("Player development tracking <i>(module)</i>",
                                              ["&mdash;", "Add-on", "Included", "Included"]),
 ("Native Android app for staff",             ["&mdash;", "on request", "Included", "Included"]),
 ("Onboarding &amp; support",                 ["Standard", "Priority", "Priority", "Dedicated"]),
],

"NOTES": "".join([
 ('<div class="note"><div class="ni">\U0001F91D</div><div><b>We set it up with you</b>'
  '<span>Centres, batches, fee rules and staff configured together &mdash; and we move your existing student list across by hand.</span></div></div>'),
 ('<div class="note"><div class="ni">\U0001F4B3</div><div><b>Fees land in your account</b>'
  '<span>Payments go direct to your UPI id. We never hold or process your money and take no cut. WhatsApp message costs are billed at actual usage.</span></div></div>'),
 ('<div class="note"><div class="ni">⚡</div><div><b>Automatic sending when you&rsquo;re ready</b>'
  '<span>Reminders send with one tap from day one. Fully automatic daily sending switches on once your WhatsApp Business number and templates are approved &mdash; we handle the submission.</span></div></div>'),
]),

"ADDONS": "".join([
 '<div class="ad"><b>Booking &amp; channel sync</b><span>module &middot; from &#8377;999/mo</span></div>',
 '<div class="ad"><b>Player development</b><span>module &middot; from &#8377;999/mo</span></div>',
 '<div class="ad"><b>Identity &amp; design work</b><span>&#8377;4,999 one-time</span></div>',
 '<div class="ad"><b>Setup &amp; data migration</b><span>from &#8377;2,999</span></div>',
]),

"CTA": "Book a live walkthrough",
"CTA_SUB": "15 minutes on your own batches and fees &mdash; no obligation",
"PHONE": "99515 97567",
"EMAIL": "tarun.sujit@gmail.com",
}
