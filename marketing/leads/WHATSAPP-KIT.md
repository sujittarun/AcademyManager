# The WhatsApp outreach kit

Written 2026-08-12. Reference figures were read from the production
database on **2026-08-12** (query in `scratchpad/refcheck2.sql`), not
quoted from a doc. Re-check them before a campaign in a later month —
a number that has drifted is worse than no number.

---

## 0. Read this first: which number you send from

Outreach goes from **8297771212**, the Academy Manager demo number.

**This was checked, not assumed.** The live reminder sender is a
different number: Meta's Graph API reports `phoneNumberId
1131427080050707` as **+91 81439 60950**, verified name "Gen Alpha
Cricket Academy", quality rating GREEN. Confirmed 2026-08-12. The two do
not collide, so cold outreach from 8297771212 cannot put reminder
delivery at risk.

**Keep it that way.** The rule behind the check:

| | |
|---|---|
| **+91 81439 60950** — the WABA behind `submit-whatsapp-templates.sh` | tenant fee reminders **only**. Never touches a prospect. |
| **8297771212** on the **WhatsApp Business App** | all cold outreach. Manual, one conversation at a time. |

Why it matters enough to verify: if a sender number gets reported by a
handful of strangers and Meta restricts it, fee reminders stop
delivering for **every live academy at once** — GenAlpha alone sends to
47 families daily. A restricted WABA is the normal outcome of
cold-messaging from a sender number. Before adding any new sending
number, re-run the same check rather than trusting the config, because
`tenants.config.whatsapp` stores Meta's `phoneNumberId`, not the digits:

```bash
curl -s "https://graph.facebook.com/v21.0/<phoneNumberId>?fields=display_phone_number,verified_name" \
  -H "Authorization: Bearer $TOKEN"
```

Also: cold marketing through the **API template** route breaches Meta's
Business Messaging Policy — templates are for people who contacted you
first. Outreach goes out by hand from the Business App, personally
typed, to numbers a business has published publicly as its contact
number. Modest volume, personalised, and stop the moment someone asks
you to.

Practical guardrails on the outreach number:
- Set up the Business profile first — name, category, website,
  a one-line "about". A recipient who sees a real business is far less
  likely to report you than one who sees an unknown number.
- **Save the contact before messaging.** Messaging a saved contact
  looks like business; messaging a stranger looks like a blast.
- New number: **~20–30 new conversations a day** for the first week,
  then ramp. Not 200 on day one.
- One message. Then wait. Never double-text before they reply.
- If someone says stop, remove them from the sheet permanently.

---

## 1. The references we may actually use

The owner cleared naming tenants. But the database says only two of them
can carry a reference, so here is what is true:

### Use freely — Raj Sports (the hero)

Verified 2026-08-12: **101 active students**, 112 enrolments,
**14 batches**, **5 centres**, **1,883 attendance records** taken,
101 payments recorded.
Centres: BTV · **Delhi Public School Miyapur** · **Hill County** · PRC ·
Pushpak. Sports: cricket, football, tennis, basketball, archery.

This is the single best reference for this campaign, and not by a small
margin: it is **in Hyderabad**, it is **multi-centre**, it runs **inside
a school and inside gated communities**, and it is **multi-sport**. That
is the exact profile of most academies on our lead list. A prospect in
Miyapur or Bachupally knows those locations.

> *"I build the software Raj Sports runs on — about 100 kids across
> 5 centres here in Hyderabad, including at DPS Miyapur and Hill
> County."*

### Use for cricket — Gen Alpha Cricket Academy

Verified 2026-08-12: **47 active students** (81 on the roster all-time),
5 batches, **1,477 attendance records**, 132 payments, most recent
payment **11 Aug 2026** — i.e. yesterday. Public site:
`genalphaacademy.in`, which a prospect can open and check.

A reference they can independently verify is worth more than a bigger
number they cannot.

### Do NOT name these

**Three of the six tenants cannot carry a reference, and one is not a
customer at all. Which ones, and the usage figures behind that call, are
in `REFERENCES-INTERNAL.md` — deliberately not in this file.**

This repo is public. A table stating that a *named* client has almost no
students is our clients' commercial information, findable by them, and
publishing it would cost more than it could ever help. The operating
rule is short enough to live here:

> **Name only Raj Sports and Gen Alpha.** If you are about to name any
> other tenant, read `REFERENCES-INTERNAL.md` first — the answer is no,
> and it explains why so you do not have to take it on faith.

One that is easy to get wrong: **"Crescent Sports Academy" is the `demo`
tenant**, our sales demo dataset, not a customer. It is populated (94
students, 8 batches, 2 centres) precisely so you can show a full-looking
screen without opening a real academy's data. Introduce it as "a demo
academy I've set up so you can see it with real volume in it" — never as
a customer. Presenting it as one is inventing a customer.

**The badminton gap is real and you should know it going in.** Badminton
is our richest Hyderabad vertical and we have no badminton customer to
name. Do not paper over it. Lead with Raj Sports instead — the
operational pain is identical whether the kids hold a racquet or a bat,
and 5 centres in Hyderabad is the credential that matters. If a prospect
asks directly "do you have any badminton academies?", the answer is
"not yet in Hyderabad — you would be the first, and that is why I want
to get it right with you." First-mover framing beats a fudge, and a
fudge gets found out.

**Say "academies running on it", not "paying customers".** Every tenant
is on `pilot` or `trial` in the subscriptions table. "Runs on" is true.
"Paying customer" is not, yet.

### The demo is a sales asset — use it

The `demo` tenant is populated: 94 students, 8 batches, 2 centres,
1,804 attendance records, 225 payments. That means you can show a
**live, full-looking screen** on a call without opening a real
academy's data. Do that instead of a slide deck. Never introduce it as
a customer — introduce it as "a demo academy I've set up so you can see
it with real volume in it."

---

## 2. Message 1 — the opener

> **THE CONSOLE IS AUTHORITATIVE. `SALES_TPL._default` in
> `AcademyManager/index.html` is what actually sends** — the Sales tab
> pre-fills it, and both A/B arms must send byte-identical text or the
> experiment means nothing. Do not retype an opener from this file into
> WhatsApp; the per-sport variants below are kept as history.

**Generation 2, from 2026-08-13** — about 30 words, down from 55:

> Hi — is this [Academy]?
>
> I'm Sujit, from Academy Manager. I build software for sports academies.
>
> How are you tracking batches and monthly fees right now — Excel, WhatsApp, or a register?

Why it looks like this. **Generation 1 went to 30 academies and got zero
replies** (A=13, B=17), which puts the true reply rate under roughly 12%.
Every line of it did something an advertisement does — "I'm from Academy
Manager" (a company with no person behind it), "We build branded apps for
coaching academies" (a positioning statement), "batches, attendance, fees
and the parent reminders in one place" (a feature list), "Same if you're a
coach running classes across a few centres" (a second segment pitch).
55 words, and the question came *after* the pitch, so it read as a
rhetorical set-up rather than curiosity. Generation 2 still names Academy
Manager — the fix was adding a person and deleting the sales copy, not
hiding who is writing.

The three rules generation 2 follows:

1. **Name yourself AND the company, and stop there.** A person can be
   replied to; a company alone gets ignored. But "Academy Manager" is
   the whole introduction — no tagline, no "to support their day-to-day
   operations", which is the phrase that made the first draft of this
   generation sound like a website again. Every piece of software
   supports day-to-day operations, so the clause carries no information.
2. **Supply the answers.** "Excel" is a complete reply. The lowest-effort
   answer a busy owner can give is the one you are most likely to get.
3. **Nothing about their business.** 57 of 112 numbers are
   directory-scraped, so asserting their branch count risks being wrong
   on line three. Asking is safe; telling is not.

Everything else — what it actually does, the demo link, the references,
the multi-centre pitch — waits for the reply. See §5.

If the copy changes again, bump **`SALES_GEN`** in `index.html` *and*
`sales_ab_generation()` in the database together, or the new opener's
reply rate gets pooled with the old one's.

---

The per-sport openers below are **generation 1 and earlier, retired.**
They are kept because the reasoning is still useful, not to be sent.

Structure, and why each line is there:

1. **Confirm their name.** Proves this is not a blast. Biggest single
   lift on reply rate.
2. **Who you are + one verified local proof.** Local beats impressive.
3. **One question about the manual thing they do every month.** Easy to
   answer, and the answer is the sale.
4. **"Before I pitch you anything."** Disarms. You *are* selling, and
   saying so plainly is what buys you the reply.

**No link in message 1.** Links from unknown numbers suppress replies
and attract spam reports. The flyer comes later, if they ask.

### Cricket

> Hi, is this [Name] from [Academy]?
>
> I'm [Your name], based here in Hyderabad. I built the app that Gen Alpha Cricket Academy runs on — attendance, fees and the parent reminders.
>
> Before I pitch you anything: how do you track which parents have paid this month and which haven't? Excel, or a register?

### Badminton · Tennis · Table tennis · Pickleball

> Hi, is this [Name] from [Academy]?
>
> I'm [Your name], from Hyderabad. I build the software Raj Sports runs on — about 100 kids across 5 centres here, including DPS Miyapur and Hill County.
>
> Before I pitch you anything: how are you keeping track of who's paid their monthly fee and who's still due?

### Swimming

> Hi, is this [Name] from [Academy]?
>
> I'm [Your name] from Hyderabad — I build the app Raj Sports uses to run their batches across 5 centres here.
>
> One question before I pitch anything: with batches turning over every month, how do you keep track of who's paid and who's due? Excel, or a register?

### Martial arts · Skating — the multi-branch opener

> Hi, is this [Name] from [Academy]?
>
> I'm [Your name], from Hyderabad. I build the software Raj Sports runs on — 5 centres, ~100 students, all on one screen.
>
> You run [N] centres. How do you see all of them in one place today — do your instructors send you the register on WhatsApp?

That last question lands hard in this vertical, because that is exactly
what happens: photos of a paper register, in a group, every evening.

### Multi-sport · sports schools (the Enterprise opener)

> Hi [Name] — is this the right number for [Academy]?
>
> I'm [Your name], based in Hyderabad. I build the platform Raj Sports runs on: 5 centres, 14 batches, 5 sports, ~100 students, in one app with their own name on it.
>
> Since you run several sports at different fees — when a parent asks what they owe, how do you work it out today?

### If the lead has no name, only an academy

> Hi — is this [Academy]?
>
> I'm [Your name] from Hyderabad, I build academy software (Raj Sports here runs on it — 5 centres, ~100 kids).
>
> Could you point me to whoever handles admissions and fees? Would rather ask them one question than pitch the wrong person.

Asking to be routed is a low-friction open, and it gets you a name.

---

## 3. Message 2 — the follow-up (+3 days, no reply)

Only once. The "then I'll leave you alone" is not politeness, it is what
makes them answer.

> [Name] — following up once, then I'll leave you alone.
>
> The bit academy owners here tell me actually hurts: chasing a dozen late parents on WhatsApp, one by one, every month.
>
> Ours does that itself — a heads-up 2 days before, one on the due date, then day 5 — each with a UPI link that already has that student's exact amount in it. Paid straight into your account. We never touch the money and take no cut.
>
> And on day 15 it stops, and hands you a call list instead. It doesn't nag your parents forever.
>
> Worth 10 minutes on a call?

**"It stops" is the best line we have.** Every owner's real fear is
software that harasses the families they see courtside every evening.
Never cut that line to save space.

---

## 4. Message 3 — the close-out (+7 days)

> Last one from me, [Name] — I don't want to be a pest.
>
> If it's useful later: I'll show you the actual screen in 10 minutes, and if you go ahead, we set up your centres, batches and fee rules with you and move your existing student list across by hand. That last part is the reason most academies stay on a spreadsheet.
>
> Number's here whenever. All the best with the academy 🙏

Then mark them nurture and stop. Three messages, no more.

---

## 5. Replies, and what to say

Message 1 deliberately withholds the product name, the demo link and every
reference. **This section is where they go.** A reply means they asked —
and an answer to a question that was actually asked is worth more than the
same words volunteered to a stranger.

### They answer the question ("Excel", "register", "WhatsApp only")

The most likely reply, and the one the opener is built for. They have just
told you their process. Name the product now, and ask for one thing.

> That's what I expected — most academies here are on exactly that.
>
> It's called Academy Manager. The part that saves the most time is the
> monthly fee reminders: it works out who's due, sends the parent a
> WhatsApp with a UPI link, and stops chasing them once they pay.
>
> Want me to send you a link you can click around in? No login, real data.

Then send their tracked demo link from the Sales tab — the console records
who opened it and how far they went, so an unanswered follow-up is not a
guess.

### "I have multiple centres" / they coach across venues

The multi-centre line was cut from message 1 for being the most
brochure-like sentence available. It belongs here, where it answers
something:

> Then this is the bit worth your time — one login across all of them.
> Each centre's batches, attendance and fees stay separate, but the money
> rolls up so you see the whole thing on one screen, plus what each centre
> is owed.

### "Who is this?" / "What is this about?"
> Sorry — [Your name], from Hyderabad. I make an app for coaching academies: attendance, fees, and the monthly WhatsApp reminders to parents with a UPI link.
>
> Raj Sports here uses it across 5 centres. I messaged you because [Academy] runs proper batches, which is exactly who it's built for.
>
> Are you the right person for admissions and fees, or should I speak to someone else?

### "Send details" — the most common reply, and a soft brush-off
Send **one** image and **ask for a time**. A wall of text here kills it.

> Sending the one-pager now.
>
> Honestly though, it makes more sense in 10 minutes on a call — I'll show you the actual screen with a real academy's batches in it, and you'll know in two minutes whether it's useful.
>
> Are you free tomorrow around 12, or is evening after 8 better?

Attach `marketing/flyer/academy-manager-flyer-social.png`. One image.
Two concrete time options, never "when are you free?"

### "How much?"
Price early means real interest. Answer straight, then reframe.

> ₹1,999/month for up to 100 active students — ₹899 if you're under 50. Annual works out to two months free. GST extra.
>
> Every plan is the full thing; you're only paying for the size of the academy, not a cut-down version.
>
> Easier way to think about it: one student's monthly fee covers the software for your whole academy. What do you charge per month?

Let *them* do that arithmetic out loud. It closes better than you saying it.

### "We already use software" / "We have an app"
> Fair enough — which one? Genuinely asking, I like knowing what's working.
>
> The two things academies usually switch to us for: the reminder ladder sends itself and then *stops* on day 15 instead of nagging, and fees go to your own UPI with no cut taken. If yours already does both, you're sorted and I'll leave it.

Naming a real reason to walk away is what makes the rest credible.

### "Not interested"
> No problem at all — thanks for replying. If it changes, I'm here. All the best 🙏

Stop. Mark it closed. Never argue.

### "Call me" / "Call after 6"
Best outcome. Lock it immediately, don't just say okay.

> Will do — calling at 6:30 this evening. If that's bad, tell me a better time and I'll work around it.

Then **actually call at 6:30.**

### They send a voice note, or you're getting no traction on text
Reply with a **20-second voice note** — same content as message 1.
In India this materially outperforms text from an unknown number: they
hear a person in Hyderabad, not a broadcast. Keep it under 30 seconds,
end on the question.

---

## 6. What NOT to send

- ❌ No "Dear Sir/Madam, we are pleased to introduce…"
- ❌ No feature list in the first message. Nobody buys a bullet list.
- ❌ No "Please let us know if interested" — it asks for nothing.
- ❌ No link in message 1.
- ❌ No forwarded message. The **Forwarded** label kills it instantly.
- ❌ No "limited time offer". These are local businesses; you may meet
  them at a tournament next month.
- ❌ Never name a tenant not cleared in §1.
- ❌ Never say "paying customer".
- ❌ Never claim a badminton customer. We don't have one yet.

---

## 7. Track this, or the list rots

Log against every lead, same day: `sent` / `replied` / `call booked` /
`not interested` / `wrong number`. Two numbers tell you if this is
working:

- **reply rate** — expect 15–30% on a personalised cold WhatsApp to a
  published business number. Under 10% means the opener is wrong, not
  the list.
- **wrong-number rate** — if `directory`-sourced numbers come back dead
  much more often than `verified` ones, stop calling directory numbers
  and go via Instagram DM instead.
