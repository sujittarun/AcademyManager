/* Runs the console's REAL Sales-tab code in node and asserts on behaviour.
 *
 *   node scripts/check-sales-view.js
 *
 * WHY THIS EXISTS
 *
 * The Sales tab has failed three times in ways no amount of reading caught,
 * and every time the shape checks passed:
 *
 *   1. A block edit deleted two clipboard helpers. The tab rendered fine in
 *      review, then threw ReferenceError on load. Rendering correctly is not
 *      being callable.
 *   2. `if (!w) return` on window.open's handle. window.open returns null
 *      whenever 'noopener' is set — that is success, not failure — so the
 *      batch card bailed before logging on every click, logged ZERO touches in
 *      its whole lifetime, and served the same names forever.
 *   3. salesAct passed no template, so sends recorded from a row counted
 *      toward no A/B generation at all.
 *
 * So these tests drive the real functions and assert on what they WRITE, not
 * on what they render. They are mutation-tested: break any of the three above
 * and the failure message names the symptom.
 *
 * FIXTURES ARE SYNTHETIC ON PURPOSE. This repo is public and the real lead
 * list is names and phone numbers of Hyderabad businesses. These tests
 * exercise view and click logic, which does not care whose numbers they are.
 */
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const salesJs = html.slice(html.indexOf("var SALES_TPL"),
                           html.indexOf("function growthView(accts) {"));
if (!salesJs || salesJs.length < 5000) {
  console.error("could not slice the sales code out of index.html");
  process.exit(1);
}

/* The console's esc() is textContent -> innerHTML, which escapes & < > but NOT
   the double quote, because a text node has no attribute context. The view
   interpolates esc() into attributes, so reproduce that exactly rather than
   being more correct than the real thing and hiding a bug. */
const escShim = `var esc = function (s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
};`;

let n = 0;
function lead(over) {
  n += 1;
  return Object.assign({
    id: "lead-" + n, name: "Synthetic Academy " + n,
    phone: "90000000" + (10 + n), alt_phones: null,
    phone_confidence: "verified", do_not_contact: false,
    stage: "new", score: 9, variant: "A", sport: "Tennis", area: "Test",
    city: "Hyderabad", contact_name: null, branches: 1, students_est: null,
    notes: null, owner: null, website_or_social: null, ref_code: "abc1234",
    next_action_on: null, next_action_kind: null, lost_reason: null,
    suggested_plan: "Starter", touch_count: 0, priority: "A",
    tech_signal: null, phone_source_url: null
  }, over || {});
}

// what sales_today() returns: buckets already ordered by the database
const L = {
  reply:   lead({ variant: "B", score: 10, stage: "replied" }),
  demo:    lead({ variant: "A", score: 9 }),
  due:     lead({ variant: "B", score: 8, stage: "contacted" }),
  fresh:   lead({ variant: "A", score: 8 }),
  dnc:     lead({ do_not_contact: true, name: "Suppressed Academy" }),
  lost:    lead({ stage: "lost", lost_reason: "uses a rival app",
                  name: "Lost Academy" })
};

function todayFixture(over) {
  return Object.assign({
    today_ist: "2026-08-14", started: 35, cap: 25, room: 0, over_cap: 10,
    held_back: 70, spent: 3,
    counts: { reply: 1, demo: 1, due: 1 },
    rows: [
      Object.assign({}, L.reply, { bucket: "reply", reason: "they answered — you are the holdup", next_step: 2, next_channel: "call", demo_hits: 0, inbound: 1, steps_done: 1 }),
      Object.assign({}, L.demo,  { bucket: "demo",  reason: "opened the demo 2x and never replied", next_step: 2, next_channel: "call", demo_hits: 2, inbound: 0, steps_done: 1 }),
      Object.assign({}, L.due,   { bucket: "due",   reason: "messaged 1d ago, delivered, no reply — call", next_step: 2, next_channel: "call", demo_hits: 0, inbound: 0, steps_done: 1 })
    ]
  }, over || {});
}

const funnel = { total: 135, reachable: 110, contacted: 39, engaged: 0,
                 booked: 0, won: 0, lost: 1, dead_number: 2, suppressed: 2,
                 why_lost: { "uses a rival app": 1 } };
const ab = { generation: "opener2",
             A: { label: "text only", assigned: 69, sent: 0, drafted: 0,
                  undelivered: 2, replied: 0, reply_rate_pct: 0 },
             B: { label: "text + one screenshot", assigned: 64, sent: 0,
                  drafted: 0, undelivered: 0, replied: 0, reply_rate_pct: 0 },
             difference_pct: 0, min_detectable_pct: null, z: 0,
             undelivered_total: 2, verdict: "too early",
             earlier_openers: { delivered: 39, replied: 0 } };

const preamble = `
${escShim}
var state = { sales: { today: TODAY, funnel: FUNNEL, leads: LEADS, ab: AB,
  done: {}, loaded: true, loading: false, notice: "", again: false,
  f: { priority: "", sport: "", stage: "", q: "", callable: true } } };
function rpc(){ return Promise.resolve({ ok: 1 }); }
function fetch(){ return Promise.resolve({ ok: true, blob: function(){ return Promise.resolve({}); } }); }
function loadSales(){}
function render(){}
${salesJs}
`;

function run(body, over) {
  const ctx = Object.assign({
    TODAY: todayFixture(), FUNNEL: funnel, AB: ab,
    LEADS: Object.keys(L).map(k => Object.assign({}, L[k])),
    OUT: null, CALLS: [],
    window: { open: function () { return null; },   // Chrome, with 'noopener'
              alert: function (m) { this.__alert = m; },
              confirm: function () { return true; },
              prompt: function () { return "because reasons"; },
              setTimeout: function () {}, ClipboardItem: function () {} },
    document: {}, navigator: { clipboard: { write: function () {} } },
    setTimeout: function () {}, Date: Date, Math: Math, JSON: JSON,
    parseInt: parseInt, String: String, Object: Object, Array: Array
  }, over || {});
  vm.createContext(ctx);
  vm.runInContext(preamble + `
    rpc = function (name, args) { CALLS.push({ fn: name, args: args });
                                  return Promise.resolve({ ok: 1 }); };
    loadSales = function () {};
  ` + body, ctx);
  return ctx;
}

const fails = [];
const ok = [];

// ── 1. the view renders, Today is first, and nothing leaks ────────────────
{
  const c = run("OUT = salesView();");
  const out = c.OUT;
  if (typeof out !== "string" || out.length < 500) fails.push("salesView() produced nothing");
  else if (/undefined/.test(out)) fails.push("'undefined' leaked into the Sales markup");
  else if (out.indexOf("Today") > out.indexOf("REACHABLE"))
    fails.push("Today is not the first thing on the page");
  else if (out.indexOf("Sending from") !== -1)
    fails.push("the sender-number banner is still rendered");
  else if (out.indexOf("Open next") !== -1 || out.indexOf("did you send it?") !== -1)
    fails.push("the old batch/confirm machinery is still rendered");
  else ok.push("Today renders first; no sender banner, no batch machinery, no 'undefined'");
}

// ── 2. the cap must refuse, out loud ─────────────────────────────────────
{
  const c = run("OUT = salesView();");
  const out = c.OUT;
  if (out.indexOf("over the safe daily limit") === -1)
    fails.push("35 sends against a cap of 25 is not reported as over the limit");
  else if (out.indexOf("70 fresh leads held back") !== -1)
    fails.push("it offers fresh leads while over the cap");
  else ok.push("over the cap: it says so, and offers no new conversations");
}

// ── 3. THE REGRESSION: message logs the send, handle or no handle ─────────
{
  const c = run(`
    var id = state.sales.today.rows[2].id;      // the 'due' lead has a phone
    salesMessage(id);
    var d = CALLS.filter(function (x) { return x.fn === "sales_disposition"; });
    OUT = { calls: d.length, what: d[0] && d[0].args.p_what,
            tpl: d[0] && d[0].args.p_template,
            body: !!(d[0] && d[0].args.p_body),
            done: !!state.sales.done[id],
            alerted: window.__alert || null };
  `);
  const o = c.OUT;
  if (o.calls !== 1)
    fails.push("Message wrote " + o.calls + " dispositions, expected 1 — window.open returned null and the send was dropped");
  else if (o.what !== "messaged")
    fails.push("Message recorded '" + o.what + "', expected 'messaged'");
  else if (!o.tpl || !/^opener\d+_/.test(o.tpl))
    fails.push("the send carries template '" + o.tpl + "' — it counts toward no A/B generation");
  else if (!o.body) fails.push("the send recorded no message body");
  else if (!o.done) fails.push("the row was not marked done, so there is no confirmation and no Undo");
  else if (o.alerted) fails.push("it alerted '" + o.alerted + "' on a successful open");
  else ok.push("Message logs 'messaged' + template though window.open returned null");
}

// ── 4. a dispositioned row confirms itself and offers Undo ────────────────
{
  const c = run(`
    var id = state.sales.today.rows[2].id;
    salesMessage(id);
    var html = salesView();
    OUT = { hasUndo: html.indexOf('data-sdo="' + id + '|undo"') !== -1,
            says: html.indexOf("message sent") !== -1 };
  `);
  if (!c.OUT.says) fails.push("a dispositioned row does not say what happened");
  else if (!c.OUT.hasUndo) fails.push("a dispositioned row offers no Undo");
  else ok.push("after acting, the row confirms it and offers Undo");
}

// ── 5. "later" must send a FUTURE date, never today ───────────────────────
{
  const c = run(`
    var id = state.sales.today.rows[2].id;
    salesDo(id, "later", new Date(Date.now() + 7 * 864e5).toISOString().slice(0, 10));
    var d = CALLS.filter(function (x) { return x.fn === "sales_disposition"; })[0];
    OUT = { when: d && d.args.p_when, what: d && d.args.p_what };
  `);
  const o = c.OUT;
  const today = new Date().toISOString().slice(0, 10);
  if (o.what !== "later") fails.push("snooze recorded '" + o.what + "'");
  else if (!o.when) fails.push("snooze sent no date — the database will refuse it");
  else if (o.when <= today) fails.push("snooze sent " + o.when + ", which is not after today");
  else ok.push("later sends a future date (" + o.when + ")");
}

// ── 6. suppressed and lost leads get no way to message them ──────────────
{
  const c = run("OUT = salesView();");
  const out = c.OUT;
  if (out.indexOf('data-smsg="' + L.dnc.id + '"') !== -1)
    fails.push("a do-not-contact lead has a Message button");
  else if (out.indexOf('data-smsg="' + L.lost.id + '"') !== -1)
    fails.push("a lost lead has a Message button");
  else if (out.indexOf("uses a rival app") === -1)
    fails.push("a lost lead does not show why it was lost");
  else ok.push("suppressed and lost leads cannot be messaged; the loss reason shows");
}

// ── 7. every helper the load path reaches is callable ────────────────────
// A block edit once deleted two clipboard helpers; the tab rendered in review
// and threw at runtime. Rendering correctly is not being callable.
{
  let err = null;
  try {
    const c = run(`
      salesPrefetchImage(); salesCopyImage();
      salesName("X Academy (Y)"); salesMsg({ name: "X Academy" });
      salesFind(state.sales.leads[0].id);
      salesTodayCard(); salesTodayRow(state.sales.today.rows[0]);
      salesDo(state.sales.leads[0].id, "no_answer");
      OUT = 1;
    `);
    if (c.OUT !== 1) err = "the load path did not complete";
  } catch (e) { err = String(e); }
  if (err) fails.push("the load path throws: " + err);
  else ok.push("every helper the nav click and load path reach is callable");
}

// ── 8. an empty day says why, rather than looking broken ─────────────────
{
  const c = run("OUT = salesView();",
                { TODAY: todayFixture({ rows: [], counts: {}, over_cap: 10 }) });
  if (c.OUT.indexOf("over the sending limit") === -1)
    fails.push("an empty day over the cap does not explain itself");
  else ok.push("an empty day explains itself instead of rendering blank");
}

ok.forEach(s => console.log("  ok   " + s));
if (fails.length) {
  console.log("\nFAILURES:");
  fails.forEach(f => console.log("  - " + f));
  process.exit(1);
}
console.log("\nsales view + click behaviour verified");
