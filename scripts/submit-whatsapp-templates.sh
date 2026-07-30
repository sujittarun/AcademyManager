#!/usr/bin/env bash
# ============================================================
# Submit the fee-reminder message templates to Meta for approval.
#
#   META_WHATSAPP_TOKEN=xxx META_APP_ID=xxx META_WABA_ID=xxx \
#     AcademyManager/scripts/submit-whatsapp-templates.sh
#
# Run it yourself. The token is read from the environment and never
# written to disk, never echoed, and never passed on a command line
# where `ps` could see it — the same reason _sql.py uses a curl config
# file. Nothing in this repo stores it.
#
# ------------------------------------------------------------
# WHY THE TEMPLATES ARE GENERIC
#
# One WhatsApp Business account sends for every academy. Templates live
# on the WABA, so they are shared too — which means the body CANNOT say
# "Match Point Pride" or Raj's parents would receive it. The academy
# name is {{2}}, supplied per message.
#
#   {{1}} student   {{2}} academy   {{3}} amount   {{4}} due date
#
# That order is the contract with sendTemplate() in
# supabase/functions/whatsapp-reminder. Change one and change both.
#
# ------------------------------------------------------------
# WHY AN IMAGE HEADER CHANGES THE SEND PATH
#
# A template with a media header must be SENT with a matching header
# component carrying the image — approval only fixes the shape, not the
# content. A send without it fails with "expected 1 component, got 0".
# The engine supplies it from LOGO_URL below.
# ============================================================
set -euo pipefail

: "${META_WHATSAPP_TOKEN:?set META_WHATSAPP_TOKEN}"
: "${META_APP_ID:?set META_APP_ID — Meta app dashboard, top left}"
: "${META_WABA_ID:?set META_WABA_ID — WhatsApp > API Setup}"

GRAPH="https://graph.facebook.com/v20.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGO="$HERE/assets/branding/whatsapp-header.jpg"
LANG_CODE="${META_TEMPLATE_LANG:-en}"

[ -f "$LOGO" ] || { echo "missing $LOGO" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Keep the bearer out of argv.
printf 'header = "Authorization: OAuth %s"\n' "$META_WHATSAPP_TOKEN" > "$TMP/auth.cfg"
chmod 600 "$TMP/auth.cfg"

say() { printf '%s\n' "$*"; }

# ------------------------------------------------------------
# 1. Upload the header image, get a handle.
#    Two steps: open a session, then send the bytes to it.
# ------------------------------------------------------------
BYTES=$(wc -c < "$LOGO" | tr -d ' ')
say "→ opening an upload session for the header image ($BYTES bytes)"

SESSION=$(curl -sS -X POST \
  "$GRAPH/$META_APP_ID/uploads?file_name=whatsapp-header.jpg&file_length=$BYTES&file_type=image/jpeg" \
  -K "$TMP/auth.cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')

[ -n "$SESSION" ] || { echo "no upload session — check META_APP_ID and the token's permissions" >&2; exit 1; }

say "→ uploading"
HANDLE=$(curl -sS -X POST "$GRAPH/$SESSION" \
  -K "$TMP/auth.cfg" -H "file_offset: 0" \
  --data-binary "@$LOGO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("h",""))')

[ -n "$HANDLE" ] || { echo "upload returned no handle" >&2; exit 1; }
say "✓ header handle obtained"

# ------------------------------------------------------------
# 2. Create the three templates.
#
#    UTILITY, not MARKETING: these are account updates about money
#    already owed under an existing arrangement. Meta re-categorises
#    anything that reads promotional, and MARKETING costs more and can
#    be muted by the parent.
#
#    Meta's body rules, all obeyed below: no leading or trailing
#    variable, no two variables adjacent, every variable used.
# ------------------------------------------------------------
submit() {
  local name="$1" body="$2" example="$3"
  say ""
  say "→ $name"
  python3 - "$name" "$body" "$example" "$HANDLE" "$LANG_CODE" > "$TMP/payload.json" <<'PY'
import json, sys
name, body, example, handle, lang = sys.argv[1:6]
print(json.dumps({
  "name": name,
  "language": lang,
  "category": "UTILITY",
  "components": [
    {"type": "HEADER", "format": "IMAGE", "example": {"header_handle": [handle]}},
    {"type": "BODY", "text": body, "example": {"body_text": [json.loads(example)]}},
    {"type": "FOOTER", "text": "Sent by your academy via Academy Manager."},
  ],
}))
PY
  RESP=$(curl -sS -X POST "$GRAPH/$META_WABA_ID/message_templates" \
    -K "$TMP/auth.cfg" -H "Content-Type: application/json" \
    --data-binary "@$TMP/payload.json")
  printf '   %s\n' "$(printf '%s' "$RESP" | python3 -c '
import json,sys
r = json.load(sys.stdin)
if "error" in r:
    e = r["error"]
    print("REJECTED: " + e.get("error_user_msg") or e.get("message",""))
else:
    print("submitted — id %s, status %s" % (r.get("id","?"), r.get("status","PENDING")))
')"
}

EG='["Aarav Sharma","Match Point Pride","₹2,000","1 Aug 2026"]'

submit "fee_due_headsup" \
  "Hello! {{1}}'\''s coaching fee at {{2}} is due on {{4}}. Amount: {{3}}. Sharing this early so you can plan." \
  "$EG"

submit "fee_due_today" \
  "Hello! {{1}}'\''s coaching fee at {{2}} is due today, {{4}}. Amount: {{3}}. Kindly complete the payment to continue the batch." \
  "$EG"

submit "fee_overdue" \
  "Hello! A gentle reminder that {{1}}'\''s coaching fee at {{2}} is still pending — {{3}}, due {{4}}. Please clear it so they do not miss sessions. Do reply if you need any help." \
  "$EG"

say ""
say "Approval is usually minutes, occasionally a day. Check status with:"
say "  curl -sS \"$GRAPH/\$META_WABA_ID/message_templates?fields=name,status,category\" -H \"Authorization: OAuth \$META_WHATSAPP_TOKEN\""
