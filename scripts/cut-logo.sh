#!/usr/bin/env bash
# Cut the brand mark out of its JPEG background into a transparent PNG.
#
#   scripts/cut-logo.sh [src.jpg] [out.png]
#
# Defaults to the demo app's mark.
#
# WHY THIS IS NOT ONE -transparent FLAG
#
# The source is a JPEG, so it has no alpha and its "white" background is not
# one colour — sampled corners come back srgb(226,216,207), srgb(234,223,217)
# and srgb(230,220,211), because JPEG compression dithers flat areas. A plain
# `-transparent white` removes almost nothing.
#
# Worse, the logo's own artwork is cream too: the infinity track is beige.
# So a global fuzzy `-transparent` eats the logo along with the background.
#
# Floodfill is the tool that distinguishes them: it only spreads through
# CONNECTED similar pixels, so starting at a corner it clears the backdrop and
# stops at the artwork's darker edges.
#
# THE PART THAT IS EASY TO MISS
#
# Corner floodfill cannot reach a region enclosed by the artwork. The mark is
# a figure-of-eight, and its right loop encloses a patch of backdrop that no
# corner touches. Cutting only from the corners left the left loop clear and
# the right loop holding a cream blob — visibly a bug. Hence the interior
# seed points below. If the artwork changes, re-sample them:
#
#   magick src.jpg -format "%[pixel:p{300,190}]" info:
#
# Quantising to 128 colours is visually identical here and takes the file from
# 160KB to 41KB — smaller than the JPEG it replaces, which matters because
# this loads on every page of a demo a prospect opens on mobile data.
set -euo pipefail

SRC="${1:-$(dirname "$0")/../../AcademyManagerDemo/assets/img/am-logo-mark.jpg}"
OUT="${2:-$(dirname "$0")/../../AcademyManagerDemo/assets/img/am-logo-mark.png}"

command -v magick >/dev/null || { echo "needs ImageMagick: brew install imagemagick" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such source: $SRC" >&2; exit 1; }

W=$(magick identify -format "%w" "$SRC")
H=$(magick identify -format "%h" "$SRC")
RX=$((W - 1)); BY=$((H - 1))

# Sample the seed colours FIRST, into variables. Doing this inline inside the
# long magick command below silently broke: the shell mangled p{300,190} and
# ImageMagick received "p190" as a stray operand, then wrote a corrupt file.
px() { magick "$SRC" -format "%[pixel:p{$1,$2}]" info:; }
C_TL=$(px 2 2)
C_TR=$(px $((W - 3)) 2)
C_BL=$(px 2 $((H - 3)))
C_BR=$(px $((W - 3)) $((H - 3)))
C_I1=$(px 300 190)
C_I2=$(px 290 160)
C_I3=$(px 350 180)

magick "$SRC" -alpha set -fuzz 20% \
  -fill none -floodfill +0+0            "$C_TL" \
  -fill none -floodfill "+${RX}+0"      "$C_TR" \
  -fill none -floodfill "+0+${BY}"      "$C_BL" \
  -fill none -floodfill "+${RX}+${BY}"  "$C_BR" \
  -fill none -floodfill +300+190        "$C_I1" \
  -fill none -floodfill +290+160        "$C_I2" \
  -fill none -floodfill +350+180        "$C_I3" \
  -trim +repage -strip -colors 128 -define png:compression-level=9 "$OUT"

# Refuse to ship a cutout that did not actually cut anything.
if [ "$(magick "$OUT" -format "%[opaque]" info:)" = "True" ]; then
  echo "FAILED: $OUT has no transparent pixels — the floodfill seeds are wrong" >&2
  rm -f "$OUT"; exit 1
fi

echo "cut $OUT"
magick identify -format "  %wx%h  %B bytes\n" "$OUT"
echo "  check it on the surface it will sit on:"
echo "    magick '$OUT' -background '#1a1830' -flatten /tmp/logo-check.png"
