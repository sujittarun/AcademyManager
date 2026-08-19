/* Runs the console's REAL detail view in node and asserts on behaviour.
 *
 *   node scripts/check-visitor-view.js
 *
 * WHY THIS EXISTS
 *
 * The "Who opened it" panel answers one question — did anyone other than
 * me open the link — and it answers with a number. A number that is wrong
 * is worse than no panel, because it reads as a measurement.
 *
 * THE FIRST VERSION OF THIS FILE PASSED WHILE THE PANEL WAS BROKEN.
 *
 * It sliced visitorCard() out of index.html and ran it against a shimmed
 * card() and esc(). Both shims existed; the real card() does not, at that
 * scope — it is declared INSIDE detailView. So the shipped console threw
 * ReferenceError the moment an academy was clicked, and every academy
 * stopped opening. The harness was green throughout. That is the same
 * failure the Sales tab had twice: rendering correctly is not being
 * callable, and a stub satisfies exactly the reference a scope error
 * would have caught.
 *
 * So this file no longer stubs anything the console owns. It loads the
 * whole <script>, hands back the real detailView, mapAccount and state
 * through one injected line, and captures the real click handler off the
 * document shim. Only the browser is faked.
 *
 * FIXTURES ARE SYNTHETIC. Real rows carry real visitors' IP addresses.
 */
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const file = path.join(__dirname, "..", "index.html");
const html = fs.readFileSync(file, "utf8");
let js = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"));

/* One injected line, at the top, where the function declarations are
   already hoisted. It cannot go at the foot: the IIFE returns early when
   nobody is signed in, which is exactly the state a test runs in. */
const before = js.length;
js = js.replace(/"use strict";/,
  '"use strict"; __x(function () { return { detailView: detailView, ' +
  'mapAccount: mapAccount, state: state, rpc: rpc }; });');
if (js.length === before) {
  console.error('could not inject the accessor — is "use strict" still there?');
  process.exit(1);
}

let getApi = null, onClick = null;
const fetchLog = [];
let canned = [];
/* The console's esc() is `createElement("i").textContent = s` read back as
   innerHTML, so the element has to do the escaping a browser does — and
   only that. A real text node escapes & < > and leaves the double quote
   alone, which matters because the view interpolates esc() into
   attributes. An element that escapes MORE than the browser would hide a
   real quoting bug. */
const el = () => ({
  _t: "",
  get textContent() { return this._t; },
  set textContent(v) {
    this._t = String(v == null ? "" : v);
    this.innerHTML = this._t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  },
  innerHTML: "", style: {}, dataset: {},
  classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  setAttribute() {}, getAttribute: () => null, hasAttribute: () => false,
  appendChild() {}, addEventListener() {}, insertAdjacentHTML() {},
  querySelector: () => null, querySelectorAll: () => [], closest: () => null,
  focus() {}, remove() {},
});
const doc = {
  createElement: el, getElementById: () => el(), querySelector: () => el(),
  querySelectorAll: () => [], body: el(), documentElement: el(), head: el(),
  readyState: "complete",
  addEventListener: (t, f) => { if (t === "click") onClick = f; },
};
const ctx = {
  __x: (g) => { getApi = g; }, document: doc, console,
  setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
  /* Installed BEFORE the script loads, and never swapped afterwards.
     Swapping it later silently recorded nothing, and the test that was
     meant to catch a dead button reported a live one as dead — while a
     second test "passed" because rpc() catches its own errors and
     returns null, so a fetch that never happened looks like one that
     succeeded. A recorder that can be bypassed is not a recorder. */
  fetch: (url, opt) => {
    fetchLog.push([String(url), opt && opt.body]);
    return Promise.resolve({ ok: true, status: 200,
      json: () => Promise.resolve(canned), text: () => Promise.resolve("") });
  },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  location: { hash: "", href: "http://x/", search: "" }, history: { replaceState() {} },
  navigator: { userAgent: "node", clipboard: { writeText: () => Promise.resolve() } },
  matchMedia: () => ({ matches: false, addEventListener() {} }),
  URL, URLSearchParams, TextEncoder, Intl,
};
ctx.window = ctx; ctx.globalThis = ctx;
vm.createContext(ctx);
try { vm.runInContext(js, ctx, { filename: "index.html" }); }
catch (e) { console.error("the console script threw on load: " + e.message); process.exit(1); }

const api = getApi();
if (!onClick) { console.error("no click handler was registered"); process.exit(1); }

/* Watch what the view asks the database for, without answering. */
const realRpc = api.rpc;
function account(over) {
  return api.mapAccount(Object.assign({
    tenant_id: "ska", name: "Super Kings Academy", sport: "Cricket",
    plan: "Starter", mrr: 2000, sub_status: "active",
    renews_on: "2026-09-30", last_write_at: new Date(Date.now() - 36e5).toISOString(),
    last_event_at: new Date(Date.now() - 36e5).toISOString(),
    actions_30d: 12, actions_prev_30d: 4, events_30d: 294,
  }, over || {}));
}
let n = 0;
function visitor(over) {
  n += 1;
  return Object.assign({
    visitor: "v_synthetic" + n, ip: "203.0.113." + n, country: "IN", edge: "MAA",
    device: "iPhone", browser: "Safari 17", os: "iOS 17", form: "phone · <400",
    visits: 2, events: 9,
    actions: null, did_something: false, is_internal: false,
    last_seen: "2026-08-19T06:00:00+00:00",
  }, over || {});
}
function view(rows, a) {
  const acct = a || account();
  api.state.sel = acct.id;
  api.state.visitors = { tenant: acct.id, loading: false, rows: rows };
  return api.detailView(acct);
}

/* The activity feed is a separate read (state.ev), so it has to be
   seeded separately. `at` must be inside the 7-day window the card
   renders or the row lands in no day bucket and disappears. */
function ev(over) {
  return Object.assign({
    name: "member_added", props: { ver: "1.0.0" }, page: "index.html",
    session_id: "s1", at: new Date(Date.now() - 36e5).toISOString(),
    visitor: "v_synthetic1", ip: "203.0.113.1",
  }, over || {});
}
function feed(events, rows, a) {
  const acct = a || account();
  api.state.sel = acct.id;
  api.state.ev = api.state.ev || {};
  api.state.ev[acct.id] = events;
  api.state.evLoading = api.state.evLoading || {};
  api.state.evLoading[acct.id] = false;
  api.state.visitors = { tenant: acct.id, loading: false, rows: rows };
  return api.detailView(acct);
}

let failed = 0;
function check(name, fn) {
  try { fn(); console.log("  ok   " + name); }
  catch (e) { failed += 1; console.log("  FAIL " + name + "\n       " + e.message); }
}
function assert(c, m) { if (!c) throw new Error(m); }

/* 0. The one the first harness could not see. */
check("clicking an academy still renders a detail view", () => {
  const h = view([visitor()]);
  assert(typeof h === "string" && h.length > 3000,
    "detailView returned " + (h && h.length) + " chars — the academy would look unclickable");
  assert(h.includes("Who opened it"), "the visitor panel is not on the page");
  assert(h.includes("Work recorded") && h.includes("App telemetry"),
    "the visitor panel displaced an existing panel");
});

check("my own devices are subtracted from the headline", () => {
  const h = view([visitor({ is_internal: true }), visitor({ is_internal: true }), visitor()]);
  const m = h.match(/>(\d+)<\/div><div style="font-size:11\.5px;color:var\(--tx4\)">real device/);
  assert(m, "no 'real devices' figure on the card");
  assert(m[1] === "1", "reads " + m[1] + " real devices — my own testing is counted as traction");
  assert(h.includes("mine, excluded"), "the excluded count is not shown, so the subtraction is invisible");
});

check("'did more than look' counts only real devices that acted", () => {
  const h = view([
    visitor({ is_internal: true, did_something: true, actions: "added a member" }),
    visitor({ did_something: true, actions: "signed in" }),
    visitor(),
  ]);
  const m = h.match(/>(\d+)<\/div><div style="font-size:11\.5px;color:var\(--tx4\)">did more than look/);
  assert(m, "no 'did more than look' figure");
  assert(m[1] === "1", "reads " + m[1] + " — my own testing counts as a user who used it");
});

check("each device carries a working toggle", () => {
  const h = view([visitor({ visitor: "v_mine", is_internal: true }), visitor({ visitor: "v_real" })]);
  assert(h.includes('data-mine="v_real" data-mine-on="1"'), "an unmarked device offers no way to claim it");
  assert(h.includes('data-mine="v_mine" data-mine-on="0"') && h.includes("Not me"),
    "a wrongly-marked device cannot be un-marked");
});

check("identity sits beside the activity, not in a panel of its own", () => {
  const h = view([visitor({ ip: "49.47.217.72", device: "Android", browser: "Chrome 127",
                            actions: "signed in, added a member", did_something: true })]);
  const row = h.slice(h.indexOf("Android"));
  ["Chrome 127", "49.47.217.72", "IN", "MAA", "signed in, added a member"]
    .forEach((s) => assert(row.includes(s), "'" + s + "' is not on the device's own row"));
  assert(row.indexOf("49.47.217.72") < row.indexOf("signed in"), "the IP is not beside what they did");
});

/* The panel called the owner's Mac a phone on its first two real rows,
   because the app's own `dev` is a viewport bucket and it won the
   coalesce. Fixed in the database (2026-08-19k); asserted here so the
   console never quietly starts preferring the page's opinion again. */
check("the device is the hardware, and the page's guess is labelled as such", () => {
  const h = view([visitor({ device: "Mac", browser: "Chrome 148", os: "macOS", form: "phone · <400" })]);
  const row = h.slice(h.indexOf("Mac"));
  assert(row.includes("Mac · Chrome 148"), "hardware and browser are not the headline for the row");
  assert(row.includes("page saw phone"), "the page's own reading is missing");
  assert(row.indexOf("Mac · Chrome 148") < row.indexOf("page saw"),
    "the page's viewport guess is being shown as the device");
});

check("no field on the card can inject markup", () => {
  ["ip", "country", "edge", "device", "browser", "os", "form", "actions", "visitor"].forEach((f) => {
    const h = view([visitor({ [f]: "<img src=x onerror=alert(1)>" })]);
    assert(!h.includes("<img src=x"), f + " is interpolated raw into the page");
  });
});

check("nobody yet reads as nobody, not as an error", () => {
  assert(view([]).includes("Nobody has opened"), "an unvisited tenant does not say so plainly");
});

/* rpc() returns null on failure and an array on success, and every other
   caller in this console writes `|| []`. Here that would print "Nobody
   has opened it" whenever the read broke — a failure wearing the clothes
   of a measurement, which is the exact trap this platform has been
   burned by before (a probe that could not tell an error body from four
   rows of data). */
check("a failed read does not report itself as zero visitors", () => {
  const h = view(null);                        // rows: null is what a failed rpc leaves behind
  assert(!h.includes("Nobody has opened"), "a broken read is being reported as nobody having visited");
  assert(h.includes("Could not read visitors"), "a broken read says nothing at all");
});

/* Switching academies must not carry the last one's visitors across.
   visitorCard guards on the tenant AND the fetch hook resets the cache,
   which is belt and braces — so assert the invariant end to end, by
   actually opening one academy after another. Testing the guard alone
   proved nothing: removing it changed no output, because the hook had
   already fired. Removing EITHER guard alone still passes, because each
   covers the other; removing both fails here. That is honest defence in
   depth rather than a mutation-proof line, and worth writing down so the
   next person does not delete one as dead code. */
check("opening a second academy never shows the first one's visitors", () => {
  const ska = account();
  api.state.sel = ska.id;
  api.state.visitors = { tenant: "ska", loading: false,
                         rows: [visitor({ ip: "49.47.217.72", device: "SKA-only phone" })] };
  assert(api.detailView(ska).includes("49.47.217.72"), "SKA's own visitor did not render");

  const leo = account({ tenant_id: "leo", name: "Leo Tennis" });
  api.state.sel = leo.id;
  const h = api.detailView(leo);
  assert(!h.includes("49.47.217.72") && !h.includes("SKA-only phone"),
    "Leo's card is showing a visitor who belongs to Super Kings");
  assert(h.includes("Reading visitors"), "Leo's card did not start its own fetch");
});

check("opening an academy asks the database for its visitors", () => {
  const a = account();
  api.state.sel = a.id; api.state.visitors = null;
  const calls = [];
  ctx.window.__probe = 1;
  const h = api.detailView(a);            // fires the fetch through the real rpc
  assert(h.includes("Reading visitors"), "the first render does not say it is loading");
  assert(api.state.visitors && api.state.visitors.tenant === "ska",
    "no fetch was started, so the panel would stay empty forever");
});

/* The operator asked for identity on each ACTIVITY, not only a roll-up
   per device: "was that member added by me testing, or by a real user?"
   is a question about one row. */
check("every activity row carries who did it", () => {
  const h = feed([ev({ ip: "49.47.217.72", visitor: "v_a" })],
                 [visitor({ visitor: "v_a", device: "Android phone", browser: "Chrome 127" })]);
  assert(h.includes("49.47.217.72"), "the activity row does not show an IP");
  assert(h.includes("Android phone Chrome 127"), "the activity row does not say which device");
});

check("the device label is not parsed a second time in the browser", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const card = src.slice(src.indexOf("function activityCard"), src.indexOf("function usageCard"));
  ["Macintosh", "iphone", "ipad", "Chrome/", "Firefox/"].forEach((needle) => {
    assert(!card.includes(needle),
      "activityCard parses the user-agent itself ('" + needle + "') — that rule already lives in tenant_visitors()");
  });
});

check("an activity from my own device is visibly not traction", () => {
  const mineRow = feed([ev({ visitor: "v_m" })],
                       [visitor({ visitor: "v_m", is_internal: true, label: "Sujit Mac" })]);
  assert(mineRow.includes("opacity:.45"), "my own activity looks identical to a real user's");
  assert(mineRow.includes("Sujit Mac"), "the label I gave the device is not shown on its activity");
  const realRow = feed([ev({ visitor: "v_r" })], [visitor({ visitor: "v_r" })]);
  assert(!realRow.includes("opacity:.45"), "a real user's activity is dimmed as though it were mine");
});

check("an activity still shows its IP before the visitor list arrives", () => {
  const h = feed([ev({ ip: "49.47.217.72" })], null);
  assert(h.includes("49.47.217.72"), "nothing identifies the row until a second request finishes");
});

check("an IP cannot inject markup into the activity feed", () => {
  const h = feed([ev({ ip: "<img src=x onerror=alert(1)>" })], []);
  assert(!h.includes("<img src=x"), "the activity row interpolates the IP raw");
});

check("the feed asks the database for the identity columns", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const q = src.slice(src.indexOf("function loadEvents"), src.indexOf("function usageArray"));
  ["visitor", "ip"].forEach((c) => assert(q.includes(c), "loadEvents never selects " + c));
});

/* The click path. The Sales tab shipped a button that rendered perfectly
   and wrote nothing for its whole lifetime, so assert on the call — and
   assert it ASYNCHRONOUSLY, because rpc() resolves a bearer token before
   it ever reaches fetch. A synchronous assertion here passed judgement
   one microtask too early and reported a working button as dead. */
async function clickChecks() {
  await check2("'That's me' marks the device and does not open the row", async () => {
    api.state.sel = "ska";
    const btn = { dataset: { mine: "v_real", mineOn: "1" }, disabled: false };
    let stopped = false;
    fetchLog.length = 0;
    onClick({
      target: { closest: (s) => (s === "[data-mine]" ? btn : null), hasAttribute: () => false },
      stopPropagation: () => { stopped = true; },
    });
    assert(btn.disabled === true, "the button stays live and can be double-fired");
    assert(stopped, "the click would also open the academy row underneath");
    await new Promise((r) => setTimeout(r, 0));
    const marks = fetchLog.filter((c) => c[0].includes("mark_visitor"));
    assert(marks.length === 1,
      "the button made " + marks.length + " mark_visitor calls — it would log zero marks for its whole lifetime");
    const body = JSON.parse(marks[0][1]);
    assert(body.p_visitor === "v_real" && body.p_internal === true && body.p_tenant === "ska",
      "wrong arguments: " + marks[0][1]);
  });

  await check2("marking forces a refetch, so the count moves", async () => {
    api.state.sel = "ska";
    api.state.visitors = { tenant: "ska", loading: false, rows: [visitor()] };
    fetchLog.length = 0;
    onClick({
      target: { closest: (s) => (s === "[data-mine]" ? { dataset: { mine: "v_real", mineOn: "1" }, disabled: false } : null),
                hasAttribute: () => false },
      stopPropagation: () => {},
    });
    await new Promise((r) => setTimeout(r, 0));
    assert(api.state.visitors === null || api.state.visitors.tenant !== "ska" || api.state.visitors.loading,
      "the cached list survived the mark, so the device would still show as a real visitor");
    fetchLog.length = 0;
    api.detailView(account());
    await new Promise((r) => setTimeout(r, 0));
    assert(fetchLog.some((c) => c[0].includes("tenant_visitors")),
      "the next render did not re-read the visitors, so the headline would not move");
  });
}

async function check2(name, fn) {
  try { await fn(); console.log("  ok   " + name); }
  catch (e) { failed += 1; console.log("  FAIL " + name + "\n       " + e.message); }
}

clickChecks().then(function () {
  console.log(failed ? "\n" + failed + " failed" : "\nall visitor-view checks passed");
  process.exit(failed ? 1 : 0);
});
