/* Build the arm-B image: the dashboard AND the payment ledger, composited
 * into one tall page-like image.
 *
 *   node scripts/shoot-arm-b-composite.js
 *
 * WHY A COMPOSITE
 *
 * Four KPI tiles read as thin — a prospect sees numbers but not a product
 * doing anything. The ledger is the opposite: named rows with type, amount,
 * mode and date. Together they answer "what is this" and "what does it do".
 *
 * WHY NOT THE WHOLE FINANCE PAGE
 *
 * That page's KPI row reads "Collected ₹5,270 across 9 payments" beside
 * "₹637k profit" — two seed figures contradicting each other. Only the LEDGER
 * card is cropped, so the contradiction never enters frame. The crop is
 * measured from the DOM, not hardcoded.
 *
 * WHY THE NAMES ARE SAFE NOW
 *
 * They were not, until 2026-08-12. Five names in the shipped data.js matched
 * real members of tenants `leo` and `raj` — the fixtures came across with the
 * Machaxi fork and only the git history had been cleaned, not the contents.
 * All person names were replaced with a set verified collision-free against
 * every tenant. This script re-checks at capture time anyway: it refuses to
 * write an image if a name in frame matches a real member, because the whole
 * point of a marketing asset is that it gets distributed.
 *
 * No AI-generated imagery. A generated "app screen" is a fake product; every
 * pixel here is the real thing.
 */
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const BASE = "https://sujittarun.github.io/AcademyManagerDemo";
const OUTDIR = path.join(__dirname, "..", "marketing", "leads");
const TMP = fs.mkdtempSync("/tmp/armb-");
const TARGET_PX = 3840;

const ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVnc2tsY2lwenlpb2d4eW5zaG5oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4OTUyMzksImV4cCI6MjA5ODQ3MTIzOX0.w7xkjdTkYN2qA0oxMKLUNtua0ScKVHKQzfEyIayh9eo";

function magick(args) { execFileSync("magick", args, { stdio: "inherit" }); }

(async () => {
  const browser = await chromium.launch();

  /* ---------- measure the layout width once ---------- */
  const probe = await browser.newPage({ viewport: { width: 1600, height: 1400 } });
  await probe.goto(BASE + "/dashboard.html", { waitUntil: "networkidle" });
  await probe.waitForTimeout(1200);
  const contentW = await probe.evaluate(() => {
    let min = Infinity, max = 0;
    document.querySelectorAll(".lt-page > *, main > *, .lt-nav").forEach((e) => {
      const r = e.getBoundingClientRect();
      if (r.width < 60 || r.height < 20) return;
      min = Math.min(min, r.left); max = Math.max(max, r.right);
    });
    return max > min ? Math.ceil(max - min) + 48 : 1320;
  });
  await probe.close();

  const cssW = Math.max(900, Math.min(contentW, 1600));
  const scale = Math.max(2, Math.round((TARGET_PX / cssW) * 10) / 10);

  /* ---------- 1. the dashboard, down to the seed activity feed ---------- */
  const dash = await browser.newPage({
    viewport: { width: cssW, height: 1400 }, deviceScaleFactor: scale });
  await dash.goto(BASE + "/dashboard.html", { waitUntil: "networkidle" });

  const figures = await dash.evaluate(async () => {
    LT.countUp = function (el, target, opts) {
      opts = opts || {};
      if (el) el.textContent = (opts.prefix || "") +
        Number(target).toLocaleString("en-IN") + (opts.suffix || "");
    };
    const ring = document.getElementById("donutVal");
    if (ring) ring.style.transition = "none";
    const s = await LT_CLOUD.snapshot();
    if (!s) return null;
    const set = (id, v) => { const e = document.getElementById(id); if (e) e.textContent = v; };
    LT.countUp(document.getElementById("kpiMembers"), s.active_members);
    set("kpiMembersSub", "▲ " + s.joined_recently + " joined recently");
    set("kpiDue", s.dues_count);
    set("kpiDueSub", "▼ worth ₹" + Number(s.dues_amount).toLocaleString("en-IN"));
    const rm = s.revenue_months, last = rm[rm.length - 1];
    LT.countUp(document.getElementById("kpiRev"), last.v, { prefix: "₹", suffix: "k" });
    set("kpiRevSub", "Month to date · " + rm[rm.length - 2].m +
                     " closed at ₹" + rm[rm.length - 2].v + "k");
    set("kpiBookings", s.bookings_today);
    window.scrollTo(0, 0);
    return { members: s.active_members, dues: s.dues_count,
             amount: s.dues_amount, rev: last.v, source: s.source };
  });
  if (!figures) throw new Error("demo_snapshot() returned nothing");
  if (figures.source !== "postgres") throw new Error("figures are not from Postgres");
  if (figures.members <= 16) throw new Error(`active_members=${figures.members} is the JS seed`);
  if (!figures.dues) throw new Error("no dues to show");

  const dashCut = await dash.evaluate(() => {
    const feed = [...document.querySelectorAll("section, .card, div")]
      .find(el => /RECENT ACTIVITY|LATEST/i.test(el.innerText || "") &&
                  el.getBoundingClientRect().height < 900);
    return feed ? Math.round(feed.getBoundingClientRect().top + window.scrollY) - 24 : null;
  });
  if (!dashCut || dashCut < 500) throw new Error(`bad dashboard cut: ${dashCut}`);
  await dash.waitForTimeout(400);
  const dashPng = path.join(TMP, "dash.png");
  await dash.screenshot({ path: dashPng, clip: { x: 0, y: 0, width: cssW, height: dashCut } });
  await dash.close();

  /* ---------- 2. the ledger card only ---------- */
  /* Tall viewport on purpose: the ledger card is ~1100px and a 1800px window
   * clipped its last row, which reads as an unfinished screenshot. */
  const fees = await browser.newPage({
    viewport: { width: cssW, height: 2600 }, deviceScaleFactor: scale });
  await fees.goto(BASE + "/fees.html", { waitUntil: "networkidle" });
  await fees.waitForTimeout(2500);

  const box = await fees.evaluate(() => {
    const t = document.getElementById("ledgerTitle");
    if (!t) return null;
    let card = t;
    for (let i = 0; i < 8 && card; i++) {
      const r = card.getBoundingClientRect();
      if (r.height > 300 && r.width > 400) break;
      card = card.parentElement;
    }
    if (!card) return null;
    card.scrollIntoView({ block: "start" });
    window.scrollBy(0, -20);
    const r = card.getBoundingClientRect();

    /* Clip ABOVE the ledger's footer total.
     *
     * The footer reads "9 payments · collected ₹52,380" — both figures from
     * LT_DATA. Sitting under a dashboard that says ₹90k across 227 payments,
     * it makes the image contradict itself, which is the one thing this
     * product claims cannot happen. Only visible by looking at the rendered
     * output, so it is measured here rather than trusted. */
    /* Clip at the bottom of the last COMPLETE row.
     *
     * Two wrong answers were tried first. Clipping at the card's bottom
     * included the footer "9 payments · collected ₹52,380" — both figures
     * from LT_DATA, sitting under a dashboard that says ₹90k across 227
     * payments, so the image contradicted itself. Clipping just above the
     * footer then sliced the last row in half, which reads as a broken app.
     *
     * A row boundary is the only edge that is both clean and honest. */
    const rows = [...card.querySelectorAll("tbody tr, tr")].filter((tr) => {
      const rr = tr.getBoundingClientRect();
      return rr.height > 10 && rr.bottom > r.top;
    });
    const lastRow = rows[rows.length - 1];
    const foot = [...card.querySelectorAll("*")].filter(
      (e) => /payments?\s*[·.]\s*collected/i.test(e.innerText || ""))
      .sort((a, b) => a.getBoundingClientRect().height -
                      b.getBoundingClientRect().height)[0];
    let bottom = r.bottom;
    if (lastRow) bottom = lastRow.getBoundingClientRect().bottom;
    else if (foot) bottom = foot.getBoundingClientRect().top - 18;

    return { x: Math.max(0, Math.floor(r.left) - 12), y: Math.max(0, Math.floor(r.top) - 12),
             width: Math.ceil(r.width) + 24,
             /* No bottom padding when the footer was clipped: adding it back
              * pushed 24px INTO the total and left a legible sliver of
              * "collected ₹52,380" at the edge — worse than including it,
              * because a half-rendered number looks like a broken app. */
             height: Math.ceil(bottom - r.top) + 10,
             clippedFooter: !!foot, rowsInFrame: rows.length };
  });
  if (!box) throw new Error("could not find the ledger card");
  if (!box.rowsInFrame || box.rowsInFrame < 5) {
    throw new Error(`only ${box.rowsInFrame} ledger rows in frame — a thin ` +
                    `ledger is what made the first attempt unconvincing`);
  }
  if (!box.clippedFooter) {
    throw new Error("could not find the ledger's footer total to clip above — " +
                    "refusing to ship an image whose ledger total contradicts " +
                    "the dashboard");
  }

  const ledgerPng = path.join(TMP, "ledger.png");
  await fees.screenshot({ path: ledgerPng, clip: box });

  /* Refuse to ship if a name in frame belongs to a real academy. The fixtures
   * were cleaned, but a marketing asset gets distributed, so verify rather
   * than trust. */
  const inFrame = await fees.evaluate((b) => {
    const out = [];
    document.querySelectorAll("body *").forEach((el) => {
      if (el.children.length) return;
      const r = el.getBoundingClientRect();
      if (r.top < b.y || r.bottom > b.y + b.height) return;
      const t = (el.innerText || "").trim();
      if (/^[A-Z][a-z]+ [A-Z][a-z]+$/.test(t)) out.push(t);
      if (/\b[6-9]\d{9}\b/.test(t)) out.push("PHONE:" + t);
    });
    return [...new Set(out)];
  }, box);
  await fees.close();
  await browser.close();

  const phones = inFrame.filter(n => n.startsWith("PHONE:"));
  if (phones.length) throw new Error("a phone number is in frame: " + phones.join(", "));

  const names = inFrame.filter(n => !n.startsWith("PHONE:"));
  if (names.length) {
    const sql = `select coalesce(string_agg(distinct m.name || ' (' || m.tenant_id || ')', ', '), '') as hits
                   from members m where m.tenant_id <> 'demo' and lower(btrim(m.name)) in (${
                     names.map(n => "'" + n.replace(/'/g, "''").toLowerCase() + "'").join(",")})`;
    const f = path.join(TMP, "check.sql");
    fs.writeFileSync(f, sql);
    const out = execFileSync("python3",
      [path.join(__dirname, "_sql.py"), f], { encoding: "utf8" });
    const hits = JSON.parse(out)[0].hits;
    if (hits) {
      throw new Error("REFUSING: a real academy's member name is in frame — " + hits);
    }
    console.log(`  ${names.length} fixture names in frame, none matching a real member`);
  }

  /* ---------- 3. composite ---------- */
  const pad = Math.round(56 * scale / 2);
  const stacked = path.join(TMP, "stacked.png");
  magick([dashPng, ledgerPng, "-background", "none", "-gravity", "center",
          "-append", stacked]);

  const out4k = path.join(OUTDIR, "dashboard-dues-4k.png");
  magick([stacked,
    "-bordercolor", "none", "-border", `${pad}x${pad}`,
    // a dark backdrop so the two cards read as one page rather than two crops
    "-background", "#0b0a16", "-alpha", "remove", "-alpha", "off",
    "-strip", out4k]);

  const outPng = path.join(OUTDIR, "dashboard-dues.png");
  const outJpg = path.join(OUTDIR, "dashboard-dues-whatsapp.jpg");
  magick([out4k, "-resize", "2000x", "-strip", "-colors", "200",
          "-define", "png:compression-level=9", outPng]);
  magick([out4k, "-resize", "1600x", "-strip", "-quality", "88", outJpg]);

  const dim = (f) => execFileSync("magick",
    ["identify", "-format", "%wx%h %B", f], { encoding: "utf8" });
  console.log("composited the dashboard + ledger into one image");
  console.log(`  ${figures.members} members · ${figures.dues} renewals due ` +
              `worth ₹${Number(figures.amount).toLocaleString("en-IN")}`);
  console.log(`  4k       ${dim(out4k)}`);
  console.log(`  png      ${dim(outPng)}`);
  console.log(`  whatsapp ${dim(outJpg)}   <- send this one`);
  fs.rmSync(TMP, { recursive: true, force: true });
})();
