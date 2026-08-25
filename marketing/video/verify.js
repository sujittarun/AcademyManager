/* Assert every recorded clip actually FILLS its frame.
 *
 * A 4K cut shipped with the app painted into the top-left quarter and grey
 * everywhere else. It passed every check made at the time — ffprobe said
 * 3840x2160 and a screenshot came back 3840x2160 — because neither measures
 * whether the CONTENT fills the frame. Playwright's context deviceScaleFactor
 * scales screenshots, not video capture.
 *
 * So: decode a frame from each clip, trim it against the known background
 * colour, and fail if the content bbox is not the full frame.
 *
 *   node verify.js
 */
const { execSync } = require("child_process");
const fs = require("fs");

const SHOTS = "/tmp/vid/shots";
const BG = "#05070f";
const TOL = 8;            // px of slack for edge antialiasing

let bad = 0, checked = 0;
for (const dir of fs.readdirSync(SHOTS).sort()) {
  const d = `${SHOTS}/${dir}`;
  const webm = fs.readdirSync(d).find((f) => f.endsWith(".webm"));
  if (!webm) { console.log(`  ${dir.padEnd(12)} NO RECORDING`); bad++; continue; }
  const src = `${d}/${webm}`;
  const png = `/tmp/vid/_v_${dir}.png`;
  execSync(`ffmpeg -v error -ss 2 -i "${src}" -frames:v 1 -y "${png}"`);
  const [W, H] = execSync(
    `ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "${src}"`
  ).toString().trim().split(",").map(Number);
  const bbox = execSync(
    `magick "${png}" -bordercolor '${BG}' -fuzz 3% -format '%@' info:`
  ).toString().trim();                       // e.g. 3840x2160+0+0
  const m = bbox.match(/(\d+)x(\d+)\+(\d+)\+(\d+)/);
  checked++;
  if (!m) { console.log(`  ${dir.padEnd(12)} bbox unreadable (${bbox})`); bad++; continue; }
  const [cw, ch] = [Number(m[1]), Number(m[2])];
  const full = cw >= W - TOL && ch >= H - TOL;
  console.log(`  ${dir.padEnd(12)} ${W}x${H}  content ${bbox}  ${full ? "FULL" : "*** PARTIAL ***"}`);
  if (!full) {
    bad++;
    console.log(`               content fills only ${Math.round((cw*ch)/(W*H)*100)}% of the frame`);
  }
  fs.unlinkSync(png);
}
console.log(bad ? `\n${bad} of ${checked} clips do not fill the frame` : `\nall ${checked} clips fill the frame`);
process.exit(bad ? 1 : 0);
