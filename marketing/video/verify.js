/* Assert every recorded clip is usable, and emit when each one becomes usable.
 *
 * TWO FAILURES THIS CATCHES, both of which shipped:
 *
 * 1. A QUARTER-FRAME CAPTURE. Playwright's context `deviceScaleFactor` scales
 *    screenshots, not video capture, so viewport 1920 + recordVideo 3840 paints
 *    1920x1080 into the top-left corner. ffprobe still says 3840x2160 and
 *    page.screenshot() still returns a full-res image, so resolution and
 *    screenshots are both useless as evidence. The tell is the content's
 *    WIDTH: half the frame instead of all of it.
 *
 * 2. TRIMMING INTO A BLANK FRAME. Clips include page-load time, and it varies
 *    wildly — one shot was still blank 3s in while another had painted by
 *    0.5s. Cutting from a fixed offset put dead frames in the edit. So this
 *    writes firstpaint.json and assemble.py refuses a trim-start earlier than
 *    the moment that clip actually painted.
 *
 * Vertical letterboxing is NOT a failure: the title and end cards are designed
 * on the same near-black as the pad colour, so trimming legitimately removes
 * their empty margins. Only width is load-bearing.
 *
 *   node verify.js        # exits non-zero if any clip is unusable
 */
const { execSync } = require("child_process");
const fs = require("fs");

const SHOTS = "/tmp/vid/shots";
const BG = "#05070f";
const PROBES = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6];
const WIDTH_TOL = 40;         // px of slack for edge antialiasing

function bbox(png) {
  try {
    const out = execSync(`magick "${png}" -bordercolor '${BG}' -fuzz 3% -format '%@' info: 2>/dev/null`)
      .toString().trim();
    const m = out.match(/(\d+)x(\d+)\+(\d+)\+(\d+)/);
    return m ? { w: +m[1], h: +m[2], x: +m[3], y: +m[4], raw: out } : null;
  } catch { return null; }
}

const report = {};
let bad = 0;

for (const dir of fs.readdirSync(SHOTS).sort()) {
  const d = `${SHOTS}/${dir}`;
  const webm = fs.readdirSync(d).find((f) => f.endsWith(".webm"));
  if (!webm) { console.log(`  ${dir.padEnd(12)} NO RECORDING`); bad++; continue; }
  const src = `${d}/${webm}`;
  const [W, H] = execSync(
    `ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "${src}"`
  ).toString().trim().split(",").map(Number);
  const len = +execSync(
    `ffprobe -v error -show_entries format=duration -of csv=p=0 "${src}"`).toString().trim();

  let firstPaint = null, widest = 0;
  for (const t of PROBES) {
    if (t > len) break;
    const png = "/tmp/_verify.png";
    try { execSync(`ffmpeg -v error -ss ${t} -i "${src}" -frames:v 1 -y ${png}`); } catch { continue; }
    const b = bbox(png);
    if (b) {
      widest = Math.max(widest, b.w);
      if (firstPaint === null && b.w >= W - WIDTH_TOL) firstPaint = t;
    }
    try { fs.unlinkSync(png); } catch {}
  }

  const fullWidth = widest >= W - WIDTH_TOL;
  const ok = fullWidth && firstPaint !== null;
  if (!ok) bad++;
  report[dir] = { width: W, height: H, length: +len.toFixed(2), first_paint: firstPaint };
  console.log(
    `  ${dir.padEnd(12)} ${W}x${H}  len ${len.toFixed(2)}s  ` +
    `widest content ${widest}px  ` +
    (ok ? `paints at ${firstPaint}s  OK`
        : `*** ${fullWidth ? "NEVER PAINTS" : `ONLY ${Math.round(widest / W * 100)}% OF THE WIDTH — quarter-frame capture`} ***`));
}

fs.writeFileSync("/tmp/vid/firstpaint.json", JSON.stringify(report, null, 1));
console.log(bad ? `\n${bad} clip(s) unusable` : `\nall ${Object.keys(report).length} clips usable; firstpaint.json written`);
process.exit(bad ? 1 : 0);
