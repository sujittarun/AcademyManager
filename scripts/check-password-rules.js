/* One question, one answer: how short may a password be?
 *
 *   node scripts/check-password-rules.js
 *
 * WHY THIS EXISTS
 *
 * There were three answers at once, and none of them was the one that
 * actually applied:
 *
 *   Supabase project policy  password_min_length = 6   <- the real rule
 *   reset.html               10
 *   access-admin function    12
 *
 * So which minimum you met depended on which door you came through, and
 * the owner kept "fixing" whichever one he happened to hit. A rule
 * stricter than the server's rejects passwords the server would have
 * taken — on a page people reach once, from a link, usually on a phone.
 *
 * This asserts each file names the number ONCE and that both agree with
 * the server. Change SERVER_MIN here only after changing it in Supabase;
 * this file follows the server, it does not decide.
 */
const fs = require("fs");
const path = require("path");

/* Read from the project's auth config on 2026-08-19:
 *   password_min_length = 6, password_required_characters = none */
const SERVER_MIN = 6;

const ROOT = path.join(__dirname, "..");
let failed = 0;
function check(name, fn) {
  try { fn(); console.log("  ok   " + name); }
  catch (e) { failed += 1; console.log("  FAIL " + name + "\n       " + e.message); }
}
function assert(c, m) { if (!c) throw new Error(m); }

const RESET = fs.readFileSync(path.join(ROOT, "reset.html"), "utf8");
const ADMIN = fs.readFileSync(path.join(ROOT, "supabase/functions/access-admin/index.ts"), "utf8");

check("reset.html states the minimum exactly once", () => {
  const decls = [...RESET.matchAll(/var MIN_PW\s*=\s*(\d+)/g)];
  assert(decls.length === 1, "found " + decls.length + " declarations of MIN_PW, expected 1");
  assert(+decls[0][1] === SERVER_MIN,
    "reset.html asks for " + decls[0][1] + " but the server's floor is " + SERVER_MIN);
});

check("reset.html has no second copy of the number", () => {
  /* A minlength attribute in the markup, or a bare literal in the check,
     is a second copy — and a second copy is exactly how this drifted. */
  assert(!/minlength\s*=\s*"\d+"/.test(RESET),
    "a minlength attribute is hardcoded in the markup; set it from MIN_PW instead");
  assert(!/length\s*<\s*\d+/.test(RESET),
    "the validation compares against a literal instead of MIN_PW");
  assert(!/At least \d+ characters/.test(RESET),
    "the sentence under the field hardcodes a number");
});

check("the access-admin function agrees with the server", () => {
  const decls = [...ADMIN.matchAll(/const MIN_SECRET\s*=\s*(\d+)/g)];
  assert(decls.length === 1, "found " + decls.length + " declarations of MIN_SECRET, expected 1");
  assert(+decls[0][1] === SERVER_MIN,
    "access-admin asks for " + decls[0][1] + " but the server's floor is " + SERVER_MIN);
  assert(!/at least \d+ characters/i.test(ADMIN),
    "the error message hardcodes a number instead of interpolating MIN_SECRET");
});

check("a GENERATED secret is still long", () => {
  /* Lowering what a person may CHOOSE says nothing about what we hand
     out. Nobody has to remember a generated one, so it stays strong. */
  const m = ADMIN.match(/pick\(abc, (\d+)\) \+ pick\(xyz, (\d+)\) \+ pick\(num, (\d+)\) \+ pick\(sym, (\d+)\) \+ pick\(all, (\d+)\)/);
  assert(m, "could not read generateSecret()'s recipe");
  const len = m.slice(1).reduce((a, n) => a + +n, 0);
  assert(len >= 14, "generated secrets are only " + len + " characters");
});

check("nothing else in the console invents a password rule", () => {
  const CONSOLE = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
  /* index.html has length checks for phone numbers and names, which are
     fine. Only a rule sitting next to the word password is a problem. */
  const lines = CONSOLE.split("\n").filter((l) =>
    /password|secret/i.test(l) && /length\s*[<>]=?\s*\d+|minlength\s*=/.test(l));
  assert(lines.length === 0,
    "the console has its own password rule:\n         " + (lines[0] || "").trim().slice(0, 110));
});

console.log(failed ? "\n" + failed + " failed" : "\nall password-rule checks passed (server floor " + SERVER_MIN + ")");
process.exit(failed ? 1 : 0);
