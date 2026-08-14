/* Runs the console's REAL Sales-tab code in node and asserts on behaviour.
 *
 *   node scripts/check-sales-view.js
 *
 * WHY THIS EXISTS
 *
 * On 2026-08-13 the batch card had logged ZERO touches across its entire
 * lifetime. Fifteen-plus openers went out by hand, the queue kept serving the
 * same names, and pressing Sent did nothing. Every shape check passed: the
 * helpers were all defined, the deployed copy matched main, PostgREST resolved
 * both RPC signatures, and the write succeeded when called with real operator
 * claims. Reading the source found nothing because the source looks correct.
 *
 * The cause was one line:
 *
 *     var w = window.open(url, "_blank", "noopener");
 *     if (!w) { alert("The browser blocked the tab."); return false; }
 *
 * `window.open` returns null whenever `noopener` is set. That is specified
 * behaviour on SUCCESS, not a failure — so the guard fired on every click and
 * returned before logging anything. The row's WhatsApp button ignored the
 * handle and logged fine; the card gated on it and logged nothing. Same
 * browser, same flag, same RPC.
 *
 * The lesson is the platform's own: a shape check cannot see behaviour. So
 * these tests drive the real functions with a stubbed `window.open` and assert
 * what was written, not what was rendered. They are mutation-tested — restore
 * the `if (!w)` gate and they fail with the exact reported symptoms.
 *
 * FIXTURES ARE SYNTHETIC ON PURPOSE. This repo is public. The real lead list
 * is names and phone numbers of Hyderabad businesses and must never be
 * committed here — see marketing/leads/.gitignore. These tests exercise view
 * and click logic, which does not care whose numbers they are.
 */
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const html = fs.readFileSync(
  path.join(__dirname, "..", "index.html"), "utf8");

// The Sales tab's own region of the console script.
const salesJs = html.slice(html.indexOf("var SALES_TPL"),
                           html.indexOf("function growthView(accts) {"));
if (!salesJs || salesJs.length < 5000) {
  console.error("could not slice the sales code out of index.html");
  process.exit(1);
}

/* The console's esc() is textContent -> innerHTML, which escapes & < > but
   NOT the double quote, because a text node has no attribute context. The
   view interpolates esc() into attributes, so reproduce that exactly rather
   than being more correct than the real thing and hiding a bug. */
const escShim = `var esc = function (s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
};`;

let n = 0;
function lead(over) {
  n += 1;
  return Object.assign({
    id: "0000000-lead-" + n, name: "Synthetic Academy " + n,
    phone: "90000000" + (10 + n), alt_phones: null,
    phone_confidence: "verified", wa_link: "https://wa.me/9190000000" + (10 + n),
    do_not_contact: false, stage: "new", last_outcome: null, last_touch_at: null,
    score: 9, priority: "A", variant: "A", sport: "Tennis", area: "Test",
    city: "Hyderabad", touch_count: 0, notes: null, owner: null,
    contact_name: null, branches: null, fees_seen: null, students_est: null,
    suggested_plan: null, tech_signal: null, next_action_on: null,
    phone_source_url: null, website_or_social: null, ref_code: "abc1234",
    demo_link: null, demo_views: 0, demo_sessions: 0, demo_last_ist: null
  }, over || {});
}

const leads = [
  lead({ variant: "A", score: 10 }), lead({ variant: "A", score: 9 }),
  lead({ variant: "A", score: 9 }),  lead({ variant: "B", score: 9 }),
  lead({ variant: "B", score: 8 }),  lead({ variant: "B", score: 8 }),
  // a suppressed lead: must never be queued, never messaged
  lead({ variant: "A", score: 9, do_not_contact: true, name: "Suppressed Academy" }),
  // an already-drafted lead: in flight, not in the queue
  lead({ variant: "B", score: 8, last_outcome: "opened", name: "Drafted Academy" })
];

const pipeline = { total: 8, callable: 7, verified: 7, no_phone: 0, dnc: 1,
                   replies_7d: 0, by_priority: { A: 4, B: 4 },
                   by_stage: { new: 7, contacted: 0, replied: 0 } };
const ab = { A: { label: "text only", assigned: 4, sent: 0, drafted: 0,
                  undelivered: 0, replied: 0, reply_rate_pct: 0 },
             B: { label: "text + one screenshot", assigned: 4, sent: 0,
                  drafted: 1, undelivered: 0, replied: 0, reply_rate_pct: 0 },
             difference_pct: 0, min_detectable_pct: null, z: 0,
             undelivered_total: 0, verdict: "too early" };

const preamble = `
${escShim}
var state = { sales: { pipeline: PIPE, leads: LEADS, ab: AB, drafted: {},
  loaded: true, loading: false, notice: "", again: false,
  from: "8297771212",
  f: { priority: "A", sport: "", stage: "", q: "", callable: true } } };
function rpc(){ return Promise.resolve({ ok: 1 }); }
function fetch(){ return Promise.resolve({ ok: true, blob: function(){ return Promise.resolve({}); } }); }
function loadSales(){}
function render(){}
${salesJs}
`;

function run(body, over) {
  const ctx = Object.assign({
    PIPE: pipeline, LEADS: leads.map(l => Object.assign({}, l)), AB: ab,
    OUT: null, CALLS: [],
    window: { open: function () { return null; },   // Chrome, with 'noopener'
              alert: function (m) { this.__alert = m; },
              confirm: function () { return true; },
              setTimeout: function () {},
              ClipboardItem: function () {} },
    document: {}, navigator: { clipboard: { write: function () {} } },
    setTimeout: function () {}
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

// ── 1. the view renders, and renders the right number of actions ──────────
{
  const c = run("OUT = salesView();");
  const out = c.OUT;
  if (typeof out !== "string" || out.length < 500) fails.push("salesView() produced nothing");
  if (/undefined/.test(out)) fails.push("'undefined' leaked into the Sales markup");
  if (out.indexOf("Suppressed Academy") !== -1 &&
      out.indexOf('data-swa="' + leads[6].id) !== -1)
    fails.push("a do-not-contact lead got a WhatsApp button");
  else ok.push("view renders, no 'undefined', suppressed lead has no send button");
}

// ── 2. THE REGRESSION: window.open returns null, the send must still log ───
{
  const c = run(`
    var before = salesQueue("A")[0];
    salesOpenOne("A");
    var logged = CALLS.filter(function (x) { return x.fn === "sales_log_touch"; });
    OUT = { name: before && before.name, id: before && before.id,
            logged: logged.length,
            outcome: logged[0] && logged[0].args.p_outcome,
            variant: logged[0] && logged[0].args.p_variant,
            drafted: !!(before && state.sales.drafted[before.id]),
            advanced: !!(before && salesQueue("A")[0] &&
                         salesQueue("A")[0].id !== before.id),
            alerted: window.__alert || null };
  `);
  const o = c.OUT;
  if (o.logged !== 1)
    fails.push("opening a lead logged " + o.logged + " touches, expected 1 — " +
               "window.open returned null and the send was dropped");
  if (o.outcome !== "opened")
    fails.push("logged outcome was " + o.outcome + ", expected 'opened' (a draft is not a send)");
  if (o.variant !== "A") fails.push("logged variant was " + o.variant + ", expected 'A'");
  if (!o.drafted) fails.push("the lead was not marked drafted, so the queue cannot advance");
  if (!o.advanced) fails.push("the queue did not advance past " + o.name +
                              " — this is the 'names are constant' bug");
  if (o.alerted) fails.push("it alerts '" + o.alerted + "' on a successful open");
  if (!fails.length) ok.push("open next: logs 'opened' though window.open returned null, and advances");
}

// ── 3. a click that does nothing must say why ─────────────────────────────
{
  const c = run(`
    state.sales.drafted = {};
    var inflight = salesInFlight("A").length;
    salesConfirmAll("A");
    OUT = { inflight: inflight, notice: state.sales.notice,
            wrote: CALLS.length, html: salesView() };
  `);
  const o = c.OUT;
  if (o.inflight !== 0) fails.push("fixture wrong: expected nothing in flight for arm A, got " + o.inflight);
  if (!o.notice) fails.push("confirming with no draft open said nothing — the dead-button bug");
  if (o.wrote !== 0) fails.push("it wrote " + o.wrote + " row(s) with nothing in flight");
  if (o.notice && o.html.indexOf(o.notice.slice(0, 25)) === -1)
    fails.push("the notice is set but never rendered, so the operator cannot see it");
  else if (o.notice) ok.push("confirm with nothing open: no write, and it explains itself on screen");
}

// ── 4. a suppressed lead is never queued or sent ──────────────────────────
{
  const c = run(`
    OUT = { qA: salesQueue("A").map(function (l) { return l.name; }),
            inflightB: salesInFlight("B").map(function (l) { return l.name; }) };
  `);
  const o = c.OUT;
  if (o.qA.indexOf("Suppressed Academy") !== -1)
    fails.push("a do-not-contact lead is in the queue");
  else if (o.inflightB.indexOf("Drafted Academy") === -1)
    fails.push("a lead whose last outcome is 'opened' is not counted as in flight");
  else ok.push("suppressed lead stays out of the queue; an 'opened' lead counts as in flight");
}

// ── 5. outbound touches carry the generation, inbound ones do not ─────────
// sales_ab_results() counts a send only if its template matches the current
// generation, so an untagged touch counts toward no experiment at all. Ten
// were logged untagged before this was caught, because salesAct — the function
// behind the row's "✓ Sent" — passed no template.
{
  const c = run(`
    salesAct("` + leads[3].id + `", "whatsapp", "sent", "out");
    salesAct("` + leads[3].id + `", "whatsapp", "replied", "in");
    OUT = CALLS.map(function (x) {
      return { dir: x.args.p_direction, tpl: x.args.p_template,
               variant: x.args.p_variant };
    });
  `);
  const [outbound, inbound] = c.OUT;
  if (!outbound || !outbound.tpl)
    fails.push("an outbound touch carries no template, so it counts in no generation");
  else if (!/^opener\d+_B$/.test(outbound.tpl))
    fails.push("outbound template is '" + outbound.tpl + "', expected <generation>_B");
  else if (outbound.variant !== "B")
    fails.push("outbound variant is " + outbound.variant + ", expected B");
  else if (inbound && inbound.tpl)
    fails.push("an inbound reply was tagged '" + inbound.tpl + "' — a reply never had a template");
  else ok.push("outbound touches carry " + outbound.tpl + "; an inbound reply carries none");
}

// ── 6. every helper the load path reaches is callable ─────────────────────
// A block edit once deleted two clipboard helpers; the tab rendered in review
// and then threw at runtime. Rendering correctly is not being callable.
{
  let err = null;
  try {
    const c = run(`
      salesPrefetchImage(); salesCopyImage();
      salesQueue("A"); salesQueue("B");
      salesInFlight("A"); salesInFlight("B");
      salesName("X Academy (Y)"); salesMsg({ name: "X Academy" });
      salesWrite("sales_log_touch", { p_lead: "x" });
      OUT = 1;
    `);
    if (c.OUT !== 1) err = "the load path did not complete";
  } catch (e) { err = String(e); }
  if (err) fails.push("the load path throws: " + err);
  else ok.push("every helper the nav click and load path reach is callable");
}

ok.forEach(s => console.log("  ok   " + s));
if (fails.length) {
  console.log("\nFAILURES:");
  fails.forEach(f => console.log("  - " + f));
  process.exit(1);
}
console.log("\nsales view + click behaviour verified");
