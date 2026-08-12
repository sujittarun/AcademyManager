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
const OUT = process.argv[2] ||
  path.join(__dirname, "..", "marketing", "leads", "dashboard-dues.png");

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 960, height: 640 },
    deviceScaleFactor: 2,          // retina, so the image is crisp on a phone
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

  // The KPI block plus the first sliver of the chart. Clipped rather than
  // full-page: the whole page is mostly chart, and the tiles are the point.
  await page.waitForTimeout(400);
  await page.screenshot({
    path: OUT,
    clip: { x: 0, y: 0, width: 960, height: 560 },
  });

  // And prove no personal data made it in — the payload has none, but the
  // page could in principle render some.
  const leaked = await page.evaluate(() => {
    const t = document.body.innerText;
    return /\b[6-9]\d{9}\b/.test(t) ? "a 10-digit phone number is on screen" : null;
  });
  await browser.close();
  if (leaked) throw new Error("refusing to save: " + leaked);

  console.log(`shot ${OUT}`);
  console.log(`  ${figures.members} members · ${figures.dues} renewals due ` +
              `worth ₹${Number(figures.amount).toLocaleString("en-IN")} ` +
              `· ₹${figures.rev}k this month`);
  console.log("  reshoot when the month changes or after demo_reset('rebuild')");
})();
