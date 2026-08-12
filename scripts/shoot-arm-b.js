/* Capture the arm-B attachment: the demo dashboard's KPI block.
 *
 *   node scripts/shoot-arm-b.js [outfile]
 *
 * Default out: marketing/leads/dashboard-dues.png
 *
 * WHY A SCRIPT AND NOT A MANUAL SCREENSHOT
 *
 * demo_reset('roll') moves the demo calendar nightly and
 * demo_spread_payments() redistributes the payment history, so the figures
 * drift. A hand-taken screenshot claiming August when it is October reads as
 * a dead product. This regenerates it in ten seconds.
 *
 * WHY IT FREEZES THE COUNT-UP
 *
 * The dashboard animates its KPIs on load via requestAnimationFrame. A
 * capture taken mid-animation shows "23" where the real figure is 94 — which
 * is exactly the understatement this whole exercise was fixing. The script
 * replaces LT.countUp with a direct write so the still shows the settled
 * state a real visitor sees a second after opening.
 *
 * WHY THE DASHBOARD AND NOT fees.html
 *
 * The Finance screen still reads from assets/js/data.js and contradicts
 * itself on the same page — "Collected 5,270 across 9 payments" next to
 * "637k profit". The demo repo's CLAUDE.md says do not demo it. Only the
 * dashboard is wired to demo_snapshot().
 *
 * It asserts the numbers before writing the file, so a broken demo produces
 * an error rather than a screenshot of zeros that gets sent to prospects.
 */
const { chromium } = require("playwright");
const path = require("path");

const URL = "https://sujittarun.github.io/AcademyManagerDemo/dashboard.html";
/* Target ~3840 device px wide (true 4K). But the viewport width is chosen to
 * MATCH the layout's content width, not fixed at 1920 — at 1920 the app
 * centres its container and leaves ~600px of empty gradient on either side,
 * which on a phone shrinks the numbers to nothing. Measure the container,
 * fit the frame to it, then scale up to reach 4K. */
const TARGET_PX = 3840;
const PROBE_W = 1600;
const OUT = process.argv[2] ||
  path.join(__dirname, "..", "marketing", "leads", "dashboard-dues.png");

(async () => {
  const browser = await chromium.launch();
  // Probe pass: how wide is the content actually laid out?
  const probe = await browser.newPage({ viewport: { width: PROBE_W, height: 1400 } });
  await probe.goto(URL, { waitUntil: "networkidle" });
  await probe.waitForTimeout(1200);
  const contentW = await probe.evaluate(() => {
    const els = [...document.querySelectorAll(".lt-page > *, main > *, .lt-nav")];
    let min = Infinity, max = 0;
    els.forEach((e) => {
      const r = e.getBoundingClientRect();
      if (r.width < 60 || r.height < 20) return;
      min = Math.min(min, r.left); max = Math.max(max, r.right);
    });
    return max > min ? Math.ceil(max - min) + 48 : null;   // + a little breathing room
  });
  await probe.close();

  const cssW = Math.max(900, Math.min(contentW || 1320, PROBE_W));
  const scale = Math.max(2, Math.round((TARGET_PX / cssW) * 10) / 10);

  const page = await browser.newPage({
    viewport: { width: cssW, height: 1400 },
    deviceScaleFactor: scale,
  });

  await page.goto(URL, { waitUntil: "networkidle" });

  // Freeze the animation, then repaint from the snapshot.
  const figures = await page.evaluate(async () => {
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
    return {
      members: s.active_members, dues: s.dues_count,
      amount: s.dues_amount, rev: last.v, source: s.source,
    };
  });

  if (!figures) {
    await browser.close();
    throw new Error("demo_snapshot() returned nothing — not shooting a blank dashboard");
  }

  // Refuse to produce an understated or empty asset.
  if (figures.source !== "postgres") throw new Error("figures are not from Postgres");
  if (figures.members <= 16) {
    throw new Error(`active_members is ${figures.members} — that is the JS seed, ` +
                    `not the real roster. Refusing to shoot it.`);
  }
  if (!figures.dues || !figures.amount) {
    throw new Error("no dues to show — reminder_queue returned nothing");
  }

  /* Clip from the top down to — but NOT including — "Recent activity".
   *
   * A full-page shot was tempting: more on screen, more convincing. But
   * probing the page found the activity feed and a "₹9,975" figure below the
   * donut come from LT_DATA, not demo_snapshot. Mixing real and seed numbers
   * in one image is the same failure as the Finance screen, just subtler —
   * and the feed prints member names, which nothing sent to a prospect
   * should.
   *
   * Everything above it is Postgres-backed: the four tiles, the six-month
   * collections chart, and the renewal donut. The boundary is measured from
   * the DOM rather than hardcoded, so a layout change cannot silently pull
   * the seed section into frame. */
  const cut = await page.evaluate(() => {
    const cards = [...document.querySelectorAll("section, .card, div")];
    const feed = cards.find(el => /RECENT ACTIVITY|LATEST/i.test(el.innerText || "") &&
                                  el.getBoundingClientRect().height < 900);
    if (!feed) return null;
    const r = feed.getBoundingClientRect();
    return Math.max(0, Math.round(r.top + window.scrollY) - 24);
  });
  if (!cut || cut < 500) {
    throw new Error(`could not locate the seed activity feed to clip above ` +
                    `(got ${cut}) — refusing to shoot the whole page`);
  }

  await page.waitForTimeout(400);
  await page.screenshot({ path: OUT, clip: { x: 0, y: 0, width: cssW, height: cut } });

  // Prove no personal data is inside the CLIPPED region. Checking the whole
  // page would be the wrong test: names below the cut are irrelevant, and a
  // phone number above it would be fatal.
  const leaked = await page.evaluate((cutY) => {
    const bad = [];
    document.querySelectorAll("body *").forEach((el) => {
      if (el.children.length) return;                 // leaf nodes only
      const r = el.getBoundingClientRect();
      if (r.top + window.scrollY > cutY) return;      // below the crop
      const t = (el.innerText || "").trim();
      if (/\b[6-9]\d{9}\b/.test(t)) bad.push("phone: " + t.slice(0, 40));
    });
    return bad.length ? bad.join("; ") : null;
  }, cut);
  await browser.close();
  if (leaked) throw new Error("refusing to save: " + leaked);

  console.log(`shot ${OUT}`);
  console.log(`  ${figures.members} members · ${figures.dues} renewals due ` +
              `worth ₹${Number(figures.amount).toLocaleString("en-IN")} ` +
              `· ₹${figures.rev}k this month`);
  console.log(`  ${cssW}px layout at ${scale}x = ${Math.round(cssW * scale)}px wide`);
  console.log("  reshoot when the month changes or after demo_reset('rebuild')");
  console.log("");
  console.log("  then make the send-ready sizes (WhatsApp recompresses anyway):");
  console.log("    cd marketing/leads");
  console.log("    cp dashboard-dues.png dashboard-dues-4k.png");
  console.log("    magick dashboard-dues-4k.png -resize 1600x -strip -quality 88 \\");
  console.log("      dashboard-dues-whatsapp.jpg      # ~130KB, this is what you send");
  console.log("    magick dashboard-dues-4k.png -resize 2000x -strip -colors 200 \\");
  console.log("      dashboard-dues.png               # ~340KB, for decks and docs");
})();
