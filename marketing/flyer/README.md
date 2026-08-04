# Flyer & sales sheet

Three artefacts, one source of truth for the copy.

| File | Use it for |
|---|---|
| `academy-manager-flyer-social.png` | **WhatsApp / Instagram.** 4:5, the shape a phone shows best. Send this with the demo video. |
| `academy-manager-flyer.png` | **Print.** A4 at 300dpi. Same content, taller page. |
| `academy-manager-sales-sheet.png` | The **leave-behind** for someone who asks for detail — access layers, full feature matrix, add-ons. Not a flyer; do not lead with it. |

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
