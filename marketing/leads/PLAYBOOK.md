# Hyderabad outreach playbook — coaching academies

## Where the data lives

The leads are **in Postgres**, not in this folder. `sales.leads`,
`sales.touches` and `sales.dnc`, in a `sales` schema that PostgREST does
not expose — verified: the API answers `PGRST106, only the following
schemas are exposed: public, graphql_public`. The only way in is the
operator console's **Sales** tab, and every entry point asserts
`am_role = 'operator'`, so tenant staff and coaches are refused. That is
behaviour-tested in `supabase/tests/2026-08-12u-sales-pipeline.sql`, and
the test is mutation-tested — removing the guard makes it fail with
"TENANT STAFF READ THE PROSPECT LIST".

**The CSVs are never committed.** They hold contact details for people
who are not our customers; `marketing/leads/.gitignore` blocks them.
Keep them in a scratch directory. To load or refresh:

```bash
AcademyManager/scripts/sales-import.py <master.csv>
```

It is idempotent on the normalised academy name, so re-running it when
another vertical's research lands updates in place. It will never
overwrite a `verified` number with a `directory` one, and it refuses to
store a number it cannot normalise — a half-recognised number must not
look callable.

**Score is computed in the database**, by one `IMMUTABLE` function behind
a stored generated column, so the console, a manual query and the
importer cannot disagree about who to call first. The table below is what
that function implements; change one and change the other.



Written 2026-08-12. Every product claim below was taken from
`marketing/flyer/content.py`, which was itself audited against the
codebase on 2026-08-04. **Do not add a claim to this file that is not
built.** A salesperson who promises a feature we do not have burns the
account and the reference.

---

## Why coaching, and not court booking

The instinct to skip the turf-and-court venues is correct, and it is
worth being able to say why out loud on a call.

| | Court booking | Coaching |
|---|---|---|
| Who already serves it | Playo, Hudle, Bookmyshow — funded aggregators who take a cut per booking | nobody, in Hyderabad, at this price |
| Revenue shape | per-hour, walk-in, unpredictable | **monthly recurring fee per student** |
| The owner's actual pain | filling empty slots (a marketing problem) | who paid, who didn't, who attended (an admin problem) |
| What we sell | `CourtSync`, an optional module | **the entire product** |

Every core function in this platform — the seven-level fee chain, the
renewal roll-forward, the reminder ladder, the attendance register — is
coaching machinery. Court booking is a bolt-on we can switch on later.
So a pure court venue is a bad-fit lead we would have to discount to
win, and a coaching academy is a full-price lead we are already built
for.

**The upsell is the other direction:** win a coaching academy that also
owns courts, then switch the booking module on. Never lead with it.

---

## Scoring: which lead gets called first

Score each lead out of 10. Call 8+ this week.

| Signal | Points | Why it matters |
|---|---|---|
| Runs monthly/quarterly fee batches | +3 | This is the product. No recurring fee, no deal. |
| Registration is a Google Form, a WhatsApp number, or a phone call | +3 | **The strongest buying signal there is.** It means the register is on paper and the fees are in a notebook or an Excel sheet. |
| 2+ centres / branches | +2 | Multi-centre is where our fee rules and coach scoping earn their keep, and it moves the deal from ₹899 to ₹3,999. |
| 50–150 active students | +2 | Lands squarely in Growth or Pro. Priced right, felt pain. |
| Publishes fees on the site | +1 | They think about pricing structure; the fee chain will land. |
| Multiple coaches | +1 | Register-only coach logins become the hook. |
| 150+ students or a chain | +1 | Enterprise conversation, but a longer sale. |
| Already has a real parent-login portal | **−3** | Someone sold them something. Requalify before spending time. |
| Pure court/turf hire, no batches | **−5** | Not our customer. Log it and move on. |
| Under ~25 students | −2 | Real pain, but the ₹899 tier is thin and churn is high. |

---

## The opening line

The mistake is opening with features. Open with the one job they do by
hand every single month.

> *"You run [sport] batches at [area] — how are you tracking who's paid
> this month, and who hasn't?"*

Then shut up. The answer is almost always "Excel", "a notebook", or "my
WhatsApp groups", and they will usually complain about it unprompted.
That complaint is the sale; everything after is confirming we fix it.

**Second question, once they've told you:**

> *"And when someone's late — who chases them?"*

The owner chases them. Personally. On WhatsApp. Every month. That is the
wound.

---

## What we say, in the order it lands

Lead with the reminder ladder and the branded app. Those two get the
meeting.

1. **"Your own app, not a login on my dashboard."**
   Their name, their colours, their logo, their web address. This
   matters more to Indian academy owners than any feature — it is
   status, and it is the thing no aggregator offers them.

2. **"The fee reminder goes out on its own, and it carries a UPI link
   with the amount already filled in."**
   The ladder, exactly as built: a heads-up 2 days before, a nudge on
   the due date, then day 5, then daily to day 14 — **then it stops and
   hands you a call list.** Say the stop out loud. Owners are afraid of
   software that nags their parents forever, and the fact that it stops
   is what proves we understand the relationship.

3. **"The money goes to your UPI. We never touch it and take no cut."**
   This kills the Playo/Hudle comparison in one sentence. It is the
   single most disarming thing on the call.

4. **"Confirm one payment and everything moves together"** — the
   renewal date rolls forward, the dues list updates, the reminder
   closes. One tap instead of three places to update.

5. **"Nobody is ever quoted the wrong amount."** Seven levels of fee
   rules — per student, per batch, per centre, per sport. Every academy
   has that one kid on an old rate or a sibling discount, and every
   academy has quoted it wrong at least once.

6. **"Your coach takes the register without seeing your fees."**
   Register-only login, scoped to the centres you assign, and it never
   shows dues or a parent's phone number. For a multi-branch owner this
   is the whole objection about "giving staff access" answered.

7. **"Parents install nothing."** No app, no password. A WhatsApp
   message and a UPI link. Say this early if they push back on
   "will parents actually use it".

---

## Pricing, and when to say it

₹899 / ₹1,999 / ₹3,999 per month for 50 / 100 / 150 active students.
Annual is ₹8,999 / ₹19,999 / ₹39,999 — **two months free.** GST extra.
150+, chains and multi-venue are a custom conversation.

Every plan is the **full manager**. Nothing in the platform gates a
feature on the plan — you pay for the size of your academy, the extra
modules and the level of service. Never imply a cut-down version
exists, because it does not, and a customer who later reads the matrix
will catch it.

**Say the price late**, after they have told you what they do by hand.
₹1,999/mo against one student's monthly fee is the frame that closes:
*one student covers the software for the whole academy.* At a typical
₹1,500–3,500 monthly coaching fee in Hyderabad, that arithmetic is
usually true in a single sentence, and it is worth letting them do it
themselves.

---

## Objections that will actually come up

| They say | Answer |
|---|---|
| "We already use WhatsApp groups." | "You do, and that's exactly the problem — the group tells everyone at once and chases nobody in particular. This messages the eleven parents who are actually late, individually, with their own amount." |
| "My students' parents won't use an app." | "They don't have to. They install nothing and remember no password. They get a WhatsApp message and tap a UPI link." |
| "Is my data safe / can other academies see it?" | Every academy is separated in the database itself, not in the screen. Coaches see only their assigned centres. **Do not embellish this** — say what is true and offer to walk them through it. |
| "Too expensive." | One student's monthly fee. Then ask how many hours a month they spend on fee follow-up, and what an hour of theirs is worth. |
| "I'll think about it." | Offer the setup, not a trial: "We'll configure your centres, batches and fee rules with you, and move your existing student list across by hand." Doing the migration for them is the close — the reason academies stay on spreadsheets is that moving off one is work. |
| "Can you do court bookings too?" | Yes, as a module — but qualify whether coaching or booking is their real business before quoting. |

---

## What we set up for them (this is the closer)

- Centres, batches, fee rules and staff configured **together, with
  them** — not a login and a manual.
- **We move their existing student list across by hand.** Say this
  plainly. It removes the only real reason to stay on a spreadsheet.
- Fees land in their own UPI account. We never hold or process the
  money and take no cut. WhatsApp message costs are billed at actual
  usage.
- Reminders send with one tap from day one. Fully automatic daily
  sending switches on once their WhatsApp Business number and templates
  are approved — **we handle that submission.** Do not promise
  same-day automatic sending; the approval is Meta's timeline, not
  ours.

---

## Before quoting a live reference, check it

We have real academies running on this, across cricket, badminton,
tennis and a multi-venue operator. That is a genuine and strong
reference — but **get the owner's permission before naming any tenant
to a prospect**, and confirm the current student and usage numbers
rather than quoting a figure from memory. A reference that turns out to
be stale or unauthorised does more damage than having none.

---

## Rules for the callers

1. **Never call a number this list marks `none`.** Reach out on the
   website form or the Instagram DM instead.
2. `directory` numbers are real but may be a call-tracking line that
   routes through the aggregator, or a stale listing. Expect a lower
   connect rate and do not treat a dead directory number as a dead
   lead — try the social handle.
3. Log the outcome against the lead the same day. A list nobody updates
   is worthless by the second week.
4. Call between **11:00–13:00 or 16:00–18:00 IST**. Coaching academies
   run early-morning and evening batches; the owner is courtside at
   06:00–09:00 and 17:00–20:00 and will not talk.
5. Ask for the **owner or academy head** by name where this list has
   one. A front-desk number reaches someone with no authority to buy.
