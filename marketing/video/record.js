/* Records the 90-second international demo, shot by shot.
 *
 * No credentials are used or needed: every screen in these three apps renders
 * publicly (verified — zero password fields on all seven pages probed). That
 * matters because entering credentials is off-limits for me, so a demo that
 * needed a login could not have been recorded at all.
 *
 * Each shot: navigate -> localise the copy -> caption -> hold/scroll -> next.
 */
const path = require("path");
const fs = require("fs");
const { chromium } = require("playwright");
const localiseSource = require("/tmp/vid/localise.js");
const injectCaption = require("/tmp/vid/caption.js");

/* 4K, and the two ways to get it wrong — both of which were shipped once.

   WRONG 1: a 3840-wide VIEWPORT. The app lays out for a 3840px screen and its
   max-width container then floats tiny in a sea of background. Worse than 1080p.

   WRONG 2: viewport 1920 + context `deviceScaleFactor: 2` + recordVideo 3840.
   The container really is 3840x2160 and a SCREENSHOT really is full-res, so it
   measures as correct — but deviceScaleFactor does not apply to video capture.
   The page paints 1920x1080 into the top-left QUARTER of the frame and the rest
   is background. That is what shipped: verified as "3840x2160" without ever
   checking the content filled it.

   RIGHT: force the browser's actual device scale factor at launch. innerWidth
   stays 1920 so the layout is the intended one, dpr is 2, and the capture is a
   full 3840x2160. verify.js asserts the content bbox fills the frame, because
   resolution alone is not evidence. */
const W = 1920, H = 1080;          // CSS layout size
const VW = 3840, VH = 2160;        // recorded pixel size
const DPR = 2;
const OUT = "/tmp/vid/shots";
const D = "https://sujittarun.github.io/AcademyManagerDemo";

// [id, url, kicker, caption, seconds, scrollTo(px) or null]
const SHOTS = [
  ["01-title", "file://" + "/tmp/vid/cards/title.html", null, null, 7, null],
  ["02-brand", `${D}/index.html`, "Your own branded app",
    "Parents see your academy — not a spreadsheet, not a group chat.", 9, 420],
  ["03-dash", `${D}/dashboard.html`, "One dashboard",
    "Members, renewals and revenue across every venue, live.", 12, null],
  ["04-members", `${D}/players.html`, "Members &amp; batches",
    "Every student, their batch, their coach, their standing.", 11, 320],
  ["05-attend", `${D}/attendance.html`, "Attendance",
    "Mark a whole batch in seconds — from the court, on a phone.", 11, null],
  ["06-fees", `${D}/fees.html`, "Fees &amp; renewals",
    "See exactly who has paid, who is due, and what it is worth.", 12, null],
  ["07-alerts", `${D}/dashboard.html`, "Automatic parent alerts",
    "Renewal due? Parents are messaged before it lapses — no chasing.", 10, 980],
  ["08-end", "file://" + "/tmp/vid/cards/end.html", null, null, 8, null],
];

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({
    channel: "chrome",
    // this is the line that makes the capture genuinely 4K, not the context option
    args: ["--hide-scrollbars", `--force-device-scale-factor=${DPR}`],
  });

  for (const [id, url, kicker, caption, secs, scrollTo] of SHOTS) {
    const ctx = await browser.newContext({
      viewport: { width: W, height: H }, deviceScaleFactor: DPR,
      recordVideo: { dir: `${OUT}/${id}`, size: { width: VW, height: VH } },
      colorScheme: "dark",
    });
    const page = await ctx.newPage();
    try {
      await page.goto(url, { waitUntil: "networkidle", timeout: 40000 });
      // the landing page runs a ~4s intro overlay before the real page shows
      await page.waitForTimeout(url.includes("index.html") ? 5200 : 1400);

      if (!url.startsWith("file://")) {
        await page.evaluate(localiseSource);
        await page.addStyleTag({ content: "::-webkit-scrollbar{display:none}" });
      }
      if (caption) {
        await page.evaluate(
          ([k, c]) => { /* injected below */ }, [kicker, caption]
        ).catch(() => {});
        await page.evaluate(
          new Function("args", `(${injectCaption.toString()})(args[0], args[1])`),
          [kicker, caption]
        );
      }
      await page.waitForTimeout(900);

      if (scrollTo) {
        // slow, even scroll so the footage reads as a camera move, not a jump
        await page.evaluate(async (target) => {
          const steps = 130, start = window.scrollY, dist = target - start;
          for (let i = 1; i <= steps; i++) {
            window.scrollTo(0, start + dist * (i / steps));
            await new Promise((r) => setTimeout(r, 22));
          }
        }, scrollTo);
      }
      await page.waitForTimeout(secs * 1000 - (scrollTo ? 3600 : 900) - 900);
      console.log(`  shot ${id} ok`);
    } catch (e) {
      console.log(`  shot ${id} FAILED: ${e.message.slice(0, 90)}`);
    }
    await ctx.close();
  }
  await browser.close();
  console.log("done");
})();
