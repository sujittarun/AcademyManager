# Flyer & sales sheet

Three artefacts, one source of truth for the copy.

| File | Use it for |
|---|---|
| `academy-manager-flyer-social.png` | **WhatsApp / Instagram.** 4:5, the shape a phone shows best. Send this with the demo video. |
| `academy-manager-flyer.png` | **Print.** A4 at 300dpi. Same content, taller page. |
| `academy-manager-sales-sheet.png` | The **leave-behind** for someone who asks for detail — access layers, full feature matrix, add-ons. Not a flyer; do not lead with it. |

## Alternative flyers — pick by who you are sending it to

| File | Sells by | Send it to |
|---|---|---|
| `flyer-b-dark.png` | **Presence.** Dark, high contrast — the only dark thing in a white WhatsApp feed. Headline: *Stop chasing fees.* | Cold outreach, where being noticed is the whole battle |
| `flyer-c-poster.png` | **Brand.** Logo-led, almost no copy. | Someone who already knows you; posters, notice boards, a follow-up after a call |
| `flyer-d-contrast.png` | **Pain.** "Right now" vs "With Academy Manager", side by side. | An owner you know is drowning in WhatsApp and Excel — they recognise themselves in the left column |
| `flyer-e-message.png` | **Proof.** The actual reminder and the parent's *Paid* reply, as a chat. | The strongest one for WhatsApp: it demonstrates the product inside the app they are reading it in |

Rebuild all four: `python3 marketing/flyer/build_variants.py`

## Rebuilding

```bash
python3 marketing/flyer/build_flyer.py   # both flyers
python3 marketing/flyer/build.py         # the detailed sales sheet
```

Copy lives in `content.py` (sheet) and in `BENEFITS` / `TIERS` at the top
of `build_flyer.py` (flyer). Change the words, re-run, done — nothing is
hand-placed in a design tool.

## Before you edit the copy

Read `AUDIT-NOTES.md`. Every claim on these was checked against the
codebase on 2026-08-04, and ten claims from the previous flyer were
removed because the product does not do them — most importantly there is
**no parent/student login**, **no payment gateway**, and **no per-plan
feature gating**. The two rules:

1. If it is not built, it does not go on the flyer.
2. Do not tier a feature the product does not actually gate.
