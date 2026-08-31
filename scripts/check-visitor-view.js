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
  'mapAccount: mapAccount, academiesView: academiesView, render: render, ' +
  'state: state, rpc: rpc }; });');
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

/* "No rows" had two causes sharing one label.

   MPP was provisioned, used for a week, and deliberately emptied for
   handover — and then read "Onboarding" for three weeks, which says we
   are midway through setting them up. Row counts cannot tell "never
   started" from "started, then cleared": both are zero. The events table
   can, because it is append-only and survived the wipe. */
const HEALTH = [
  [null, 0,   "Onboarding", "no rows and nothing ever happened — genuinely new"],
  [null, 123, "Emptied",    "no rows, but real work is on record — cleared, not new"],
  [2,    123, "Active",     "wrote something two hours ago"],
  [24*10,0,   "Quiet",      "wrote ten days ago"],
  [24*40,0,   "At risk",    "wrote forty days ago"],
];
check("an emptied tenant is not an onboarding one", () => {
  HEALTH.forEach(function (c) {
    const a = api.mapAccount({
      tenant_id: "t", name: "T", config: {},
      last_write_at: c[0] === null ? null : new Date(Date.now() - c[0] * 36e5).toISOString(),
      action_events_ever: c[1],
    });
    assert(a.health === c[2], c[3] + " → expected " + c[2] + ", got " + a.health);
  });
});

check("an emptied tenant is not told it recorded nothing", () => {
  const emptied = api.mapAccount({ tenant_id: "mpp", name: "MPP", config: {},
    last_write_at: null, action_events_ever: 123, events_30d: 302,
    last_action_at: "2026-08-04T17:14:00+00:00" });
  api.state.data = [emptied];
  const h = api.academiesView(api.state.data);
  assert(!h.includes("nothing recorded"), "an emptied tenant is told it never recorded anything");
  assert(h.includes("Emptied"), "the card does not say it was emptied");
  assert(h.includes("123"), "the work it did do is not shown");

  const never = api.mapAccount({ tenant_id: "new", name: "New", config: {},
    last_write_at: null, action_events_ever: 0, events_30d: 12 });
  api.state.data = [never];
  const h2 = api.academiesView(api.state.data);
  assert(h2.includes("nothing recorded"), "a genuinely idle tenant lost its warning");
});

/* ONE SIGN-IN, EVERY APP.

   Every tenant app is on this same origin, so a session written here is
   a session they find. The launcher's whole job is to put the right
   token under the right key — get a key wrong and the app silently
   stays signed out, which looks like the launcher did nothing. */
/* Adding a nav item means adding a titles[] entry, and forgetting is
   silent until someone clicks it: render() read titles[view][0] and
   threw, blanking the whole console. Found by opening the page, not by
   any check that existed at the time — so it is a check now. */
check("every nav view has a title and none of them blanks the console", () => {
  const api2 = getApi();
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const views = [...src.matchAll(/navBtn\("(\w+)"/g)].map((m) => m[1]);
  assert(views.length >= 6, "only found " + views.length + " nav items");
  /* A check that silently skips is worse than no check: the first cut of
     this one "passed" because render was not exported, while the console
     was genuinely broken. */
  assert(typeof api2.render === "function", "render() is not reachable, so this check tests nothing");
  views.forEach((v) => {
    api2.state.view = v; api2.state.sel = null; api2.state.loaded = true;
    api2.state.data = api2.state.data || [];
    try { api2.render(); }
    catch (e) { throw new Error('clicking "' + v + '" throws: ' + e.message); }
  });
});

check("the launcher targets a real key and URL for every app", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const block = src.slice(src.indexOf("var APPS = ["), src.indexOf("var ELSEWHERE"));
  const keys = [...block.matchAll(/key:\s*"([^"]+)"/g)].map((m) => m[1]);
  const urls = [...block.matchAll(/url:\s*"([^"]+)"/g)].map((m) => m[1]);
  assert(keys.length >= 6, "only " + keys.length + " apps are wired up");
  assert(new Set(keys).size === keys.length, "two apps share a localStorage key — one would overwrite the other");
  /* A cross-origin URL cannot see this origin's localStorage at all, so
     seeding a key for it would show a green tick against an app that is
     still signed out. */
  urls.forEach((u) => assert(u.startsWith("https://sujittarun.github.io/"),
    u + " is not on this origin, so seeding its session cannot work"));
});

/* Activity is what the operator opens the page for, and it sat third,
   below two charts. Expanding a busy day then made the card so tall the
   panels beside it were a page away — so it goes first AND scrolls
   inside itself. */
check("activity comes first and keeps its own height", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const grid = src.slice(src.indexOf('<div class="dgrid">'), src.indexOf('card("Work recorded"'));
  const act = grid.indexOf("activityCard(a)");
  const gross = grid.indexOf('card("Gross volume"');
  assert(act >= 0 && gross >= 0, "could not find the left column's panels");
  assert(act < gross, "activity is still below the charts");

  /* The list scrolls, not the card: the heading and day counts must stay
     put, or expanding 56 rows scrolls the title out of view. */
  /* Strip comments before asserting. The first cut of this check
     matched the word "overscroll-behavior:contain" in the comment ABOVE
     the code and passed while the style itself had been removed — a
     check that reads its own explanation is not a check. */
  const fn = src.slice(src.indexOf("function activityCard(a)"), src.indexOf("function detailView(a)"))
    .replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
  assert(/max-height:\d+px;overflow-y:auto/.test(fn),
    "the activity list has no height cap, so a busy day makes the page enormous");
  assert(/overscroll-behavior:contain/.test(fn),
    "a flick past the end of the list will jump the whole page");
  const cap = +(fn.match(/max-height:(\d+)px/) || [0, 0])[1];
  assert(cap >= 260 && cap <= 700, "a " + cap + "px window is the wrong size to read a day in");
});

/* "+14 more actions" was a line of dead text: six rows rendered, the
   rest counted and unreachable, on the one panel whose job is to say
   what happened. The count was right and the operator still could not
   see them. */
check("a day with more than six actions can be opened", () => {
  const many = [];
  for (let i = 0; i < 20; i++) many.push(ev({ name: "payment_recorded", props: {} }));
  const acct = account();

  let h = feed(many, [], acct);
  assert(/Show all 20/.test(h), "there is no way to see the rest: " + (h.match(/\+\d+ more[^<]*/) || ["nothing"])[0]);
  assert(!/>\+14 more actions</.test(h), "the dead text is back");

  /* Six rows collapsed, twenty when opened. Counting the rows is the
     only way to know the button does anything. */
  const rowsOf = (html) => (html.match(/class="act-row"/g) || []).length;
  const collapsed = rowsOf(h);
  api.state.openDays[acct.id + "|" + api.state.day] = true;
  const key = Object.keys(api.state.openDays)[0];
  api.state.openDays = {};
  /* Drive it through the real click handler rather than setting state. */
  onClick({ target: { closest: (s) => (s === "[data-moreday]"
    ? { getAttribute: () => (h.match(/data-moreday="([^"]+)"/) || [])[1] } : null) },
    stopPropagation() {} });
  const opened = rowsOf(api.detailView(acct));
  assert(opened > collapsed,
    "clicking showed " + opened + " rows, same as the collapsed " + collapsed);
  assert(opened === 20, "expected all 20 rows, got " + opened);
});

/* The console never refreshed. loadEvents cached per tenant forever,
   the portfolio was read once at boot, and there was no polling, no
   realtime and no focus handler — so clicking out of an academy and
   back in showed the rows from sign-in. The operator was reloading the
   page by hand without knowing that was the only thing that worked. */
check("re-entering an academy re-reads it instead of serving the cache", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const fn = src.slice(src.indexOf("function loadEvents(id"), src.indexOf("function usageArray"));
  assert(/function loadEvents\(id, force\)/.test(fn), "loadEvents cannot be forced to re-read");
  assert(/state\.ev\[id\] && !force/.test(fn), "the cache is still unconditional");
  const open = src.slice(src.indexOf('var open = e.target.closest("[data-open]")'),
                         src.indexOf('var open = e.target.closest("[data-open]")') + 700);
  assert(/loadEvents\(state\.sel, true\)/.test(open),
    "opening an academy does not force a re-read, so clicking in and out shows stale rows");
});

/* The two reads cost very different amounts — 421ms for the portfolio
   against 0.5ms for one tenant's events — so one interval for both would
   be either wasteful or too slow. Measured, not guessed. */
check("the expensive read polls less often than the cheap one", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const m = src.match(/var LIVE = \{ events: (\d+), portfolio: (\d+)/);
  assert(m, "the live refresher is gone");
  const ev = +m[1], port = +m[2];
  assert(ev >= 5000, "events poll every " + ev + "ms — that is a request storm");
  assert(port > ev, "the 421ms portfolio read polls as often as the 0.5ms one");
  /* A console left open on a second monitor must cost nothing. */
  assert(/document\.hidden/.test(src.slice(src.indexOf("function liveTick"), src.indexOf("function liveStart"))),
    "it keeps polling while the tab is hidden");
  /* Coming back to the tab is the strongest signal something happened. */
  assert(/visibilitychange/.test(src), "returning to the tab does not refresh");
});

check("the page says when it last read anything", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  assert(/function liveAgo\(/.test(src), "there is no last-updated indicator");
  assert(/data-refresh="1"/.test(src), "there is no way to force a refresh by hand");
  const h = src.slice(src.indexOf("data-refresh=\"1\""), src.indexOf("data-refresh=\"1\"") + 700);
  assert(/liveAgo\(\)/.test(h), "the indicator does not show the age of the data");
});

/* The detail line fell back to the page filename, so a single-page app
   showed "app.html" against every row — six identical lines of nothing.
   It stays for multi-page apps, where the page IS the information. */
check("the page name is shown only when it tells them apart", () => {
  /* One page for every row: the filename is noise. */
  let h = feed([ev({ name: "attendance_marked", page: "app.html", props: {} }),
                ev({ name: "student_added",     page: "app.html", props: {} })], []);
  assert(!h.includes("app.html"), "a single-page app still shows its filename on every row");

  /* Different pages: the filename is the only thing telling them apart. */
  h = feed([ev({ name: "attendance_marked", page: "attendance.html", props: {} }),
            ev({ name: "student_added",     page: "students.html",   props: {} })], []);
  assert(h.includes("attendance.html") || h.includes("students.html"),
    "a multi-page app lost the page name, which is what distinguishes its rows");
});

/* Telemetry carries counts, never money — the tenant apps are right to
   omit amounts. The console then printed inr(undefined), which is "₹0",
   so an academy that had collected ₹48,750 showed sixty-two lines of
   "Payment recorded · ₹0". A fabricated zero is worse than a blank: it
   is a number, and it is wrong. */
check("an event with no amount shows no amount, not zero", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const fn = src.slice(src.indexOf("function evDetail(e) {"), src.indexOf("function evTime("));
  assert(/function money\(/.test(src.slice(src.indexOf("An ABSENT amount"), src.indexOf("function evDetail(e) {") + 200)),
    "the money() guard is gone");
  assert(!/inr\(p\.amount\)/.test(fn),
    "evDetail still calls inr() on a possibly-absent amount, which renders zero");
  /* Every tenant's word for the same event must be handled, or it falls
     through to showing the page filename. */
  ["expense_added", "expense_recorded"].forEach((n) =>
    assert(fn.includes('case "' + n + '"'), n + " falls through to the default branch"));
});

/* A setup link must land on a page that can READ a recovery fragment.
   Pointing at each app's login.html meant landing on a sign-in form that
   ignores it — and for MatchPointPride and GenAlpha there was no such
   file at all, so the link 404'd. One destination now, branded per
   tenant by ?t=. */
check("every setup link lands on the reset page, with the academy named", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  assert(!/APP_LOGIN/.test(src),
    "the old per-app login map is back; a sign-in page cannot read a recovery fragment");
  const fn = src.match(/function appLoginFor\(id\)\s*\{([^}]*)\}/);
  assert(fn, "appLoginFor() is gone, so nothing builds the setup link");
  assert(/reset\.html/.test(src.slice(src.indexOf("var RESET_PAGE"), src.indexOf("var RESET_PAGE") + 200)),
    "the setup link no longer points at a reset page");
  assert(/\?t=/.test(fn[1]) && /encodeURIComponent/.test(fn[1]),
    "the tenant is not passed, so every academy would see a generic page");

  /* Both writers must use it. One of them slipping back to a raw URL is
     how half the academies ended up on a dead link last time. */
  const uses = (src.match(/body\.redirectTo = appLoginFor\(id\)/g) || []).length;
  assert(uses >= 2, "only " + uses + " of the invite paths use appLoginFor()");
  assert(!/redirectTo\s*=\s*"https?:/.test(src), "a redirectTo is hardcoded somewhere");
});

check("the reset page brands itself for every academy the console knows", () => {
  const reset = require("fs").readFileSync(require("path").join(__dirname, "..", "reset.html"), "utf8");
  const brands = reset.slice(reset.indexOf("var BRANDS = {"), reset.indexOf("var BRAND ="));
  assert(brands.length > 100, "the reset page has no branding table");
  ["mezzo", "mpp", "ska", "raj", "leo", "demo", "genalpha"].forEach((t) =>
    assert(new RegExp("\\b" + t + ":\\s*\\{").test(brands), t + " has no branding on the reset page"));
  /* An unknown id must fall back, never throw: a reset is the one page
     that has to work when everything else about a person is unknown. */
  assert(/BRANDS\[t\] \|\| \{/.test(reset), "an unknown ?t= would break the page");
  /* And the finish button must go to the academy, not the console. */
  assert(/b\.href = BRAND\.app/.test(reset), "the page still sends people back to the console");
});


/* A repo name guessed from a local folder is not a URL. These two were
   both wrong on the first cut, and a launcher pointing at a 404 is worse
   than none: the session IS seeded, so only the link looks broken. */
check("no launcher URL uses a name that was only ever a local folder", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const apps = src.slice(src.indexOf("var APPS = ["), src.indexOf("var ELSEWHERE"));
  ["/Mezzo/", "/SuperKingsAcademy/"].forEach((bad) => {
    assert(!apps.includes(bad),
      bad + " is a local folder name, not a published site — it returns 404");
  });
});

check("the launcher signs in as whoever is looking at the console", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const fn = src.slice(src.indexOf("function appsSignIn("), src.indexOf("function academiesView("));
  assert(/amSession\(\)/.test(fn), "it reads the email from somewhere other than the live session");
  assert(!/state\.me/.test(fn), "state.me does not exist on this console");
  /* Six grants, not one shared token: sharing would rotate and sign the
     other five out about an hour into a demo. */
  assert(/APPS\.map/.test(fn), "it does not sign in per app, so all apps would share one refresh token");
});

check("the launcher never stores the password and never prefills it", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
  const view = src.slice(src.indexOf("function appsView("), src.indexOf("function appsSignIn("));
  assert(!/<input[^>]*appsPw[^>]*value=/.test(view), "the password field is prefilled — this file is public");
  const fn = src.slice(src.indexOf("function appsSignIn("), src.indexOf("function academiesView("));
  assert(!/localStorage\.setItem\([^)]*(pw|password)/i.test(fn), "the password is being persisted");
  assert(!/state\.(pw|password)/.test(fn + view), "the password is kept on app state");
});

/* THE BADGE THAT CRIED WOLF.

   Every tenant was a pilot whose review date had passed, and the rule
   was "status says overdue OR the date is behind us", so the console
   showed money as late on six accounts that had never been invoiced —
   including two whose own subscription notes read "placeholder MRR".
   A red badge that is always on tells you nothing.

   The rule now needs BOTH: a paying account AND a date behind it. These
   cases are the whole contract, one row each, because the failure was
   not a typo — it was a rule that read one field and needed two. */
const BILL = [
  ["paying",  "2099-01-01", "paying",  "real money, invoice not yet due"],
  ["paying",  "2020-01-01", "overdue", "real money, invoice date passed"],
  ["trial",   "2099-01-01", "trial",   "evaluating, still inside the window"],
  ["trial",   "2020-01-01", "decide",  "trial ran out — a decision is due, not a debt"],
  ["free",    "2020-01-01", "free",    "never billed, so a past date means nothing"],
  ["free",    null,         "free",    "never billed, no date at all"],
  ["churned", "2020-01-01", "churned", "gone; not a debt either"],
  [null,      "2020-01-01", "free",    "no subscription row yet"],
];
check("only a paying account with a date behind it is overdue", () => {
  BILL.forEach(function (c) {
    const a = api.mapAccount({ tenant_id: "t", name: "T", config: {},
                               sub_status: c[0], renews_on: c[1], mrr: 0,
                               last_write_at: new Date().toISOString() });
    assert(a.bill === c[2],
      c[3] + " → expected " + c[2] + ", got " + a.bill);
  });
});

check("a zero-MRR account can never show as overdue", () => {
  ["trial", "free", "churned", null].forEach(function (st) {
    const a = api.mapAccount({ tenant_id: "t", name: "T", config: {}, sub_status: st,
                               renews_on: "2020-01-01", mrr: 0,
                               last_write_at: new Date().toISOString() });
    assert(a.bill !== "overdue", st + " with a past date reads as money owed");
  });
});

/* Every state must NAME itself on the card. The paying state used to
   render an empty label, which on a dashboard is indistinguishable from
   a value that failed to load — and it is the only good news here. */
check("every billing state names itself on the card", () => {
  [["paying", "2099-01-01", "Paying"], ["paying", "2020-01-01", "Overdue"],
   ["trial", "2099-01-01", "Trial"],   ["trial", "2020-01-01", "Trial ended"],
   ["free", null, "Free"]].forEach(function (c) {
    const a = api.mapAccount({ tenant_id: "t", name: "T", config: {}, sub_status: c[0],
                               renews_on: c[1], mrr: 899,
                               last_write_at: new Date().toISOString() });
    api.state.data = [a];
    const h = api.academiesView(api.state.data);
    assert(h.includes(c[2]), c[0] + " renders no label saying \"" + c[2] + "\"");
  });
});

check("the date says which kind of date it is", () => {
  function label(st, d) {
    return api.mapAccount({ tenant_id: "t", name: "T", config: {}, sub_status: st,
                            renews_on: d, mrr: 0,
                            last_write_at: new Date().toISOString() }).renews;
  }
  assert(/^Trial ends /.test(label("trial", "2099-09-01")), "a running trial: " + label("trial", "2099-09-01"));
  assert(/^Trial ended /.test(label("trial", "2020-01-01")), "a lapsed trial: " + label("trial", "2020-01-01"));
  assert(/^Overdue since /.test(label("paying", "2020-01-01")), "a late invoice: " + label("paying", "2020-01-01"));
  assert(label("free", "2020-01-01") === "—", "a free account shows a date it does not have: " + label("free", "2020-01-01"));
});

/* raj and matchpoint have no config.sport, and the strapline
   concatenated it raw: "undefined · Hyderabad" on the live console for
   two of six academies. The word "undefined" on an operator dashboard
   reads as a broken integration, not a missing config key. */
check("an academy with no sport configured does not read as undefined", () => {
  const a = api.mapAccount({ tenant_id: "raj", name: "Raj Sports",
                             config: { city: "Hyderabad" },
                             last_write_at: new Date().toISOString() });
  assert(!/undefined/.test(a.sub), "the strapline is '" + a.sub + "'");
  assert(a.sub === "Multi-sport · Hyderabad", "unexpected strapline: " + a.sub);
  assert(a.sport === "Multi-sport", "the sport itself is " + a.sport);

  const noCity = api.mapAccount({ tenant_id: "x", name: "X", config: {},
                                  last_write_at: new Date().toISOString() });
  assert(noCity.sub === "Multi-sport", "a dangling separator: '" + noCity.sub + "'");

  const full = api.mapAccount({ tenant_id: "ska", name: "SKA",
                                config: { sport: "Cricket", city: "Coimbatore" },
                                last_write_at: new Date().toISOString() });
  assert(full.sub === "Cricket · Coimbatore", "a configured academy broke: " + full.sub);
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
