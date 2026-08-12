// An unset feature flag must mean "use the default", not "off".
//
// env() returns "" for a secret that was never set. parseBoolean read that empty string
// as a string answer and returned `"" === "true"` — false — so the `true` fallback was
// unreachable. WHATSAPP_DIRECT_PAY_ENABLED is not set on the platform project, so when
// this function moved there, direct-pay reminders silently switched off: every heads-up,
// renewal-day and overdue message went out on the old plan-button templates instead of
// the Pay Now one, with no fallback event to show it had happened.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

function parseBoolean(value: unknown, fallback: boolean): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (!normalized) return fallback;
    if (["true", "1", "yes", "on"].includes(normalized)) return true;
    if (["false", "0", "no", "off"].includes(normalized)) return false;
    return fallback;
  }
  return fallback;
}

Deno.test("an unset flag falls back to its default instead of reading as false", () => {
  // The direct-pay case: no secret set, default on.
  assertEquals(parseBoolean("", true), true);
  assertEquals(parseBoolean("   ", true), true);
  // Flags that default off stay off when unset.
  assertEquals(parseBoolean("", false), false);
});

Deno.test("an explicit value still wins over the default", () => {
  assertEquals(parseBoolean("false", true), false);
  assertEquals(parseBoolean("FALSE", true), false);
  assertEquals(parseBoolean("off", true), false);
  assertEquals(parseBoolean("0", true), false);
  assertEquals(parseBoolean("true", false), true);
  assertEquals(parseBoolean("TRUE ", false), true);
  assertEquals(parseBoolean("1", false), true);
  assertEquals(parseBoolean("yes", false), true);
});

Deno.test("booleans and unparseable values behave", () => {
  assertEquals(parseBoolean(true, false), true);
  assertEquals(parseBoolean(false, true), false);
  // A stored setting that is missing entirely, and a value we cannot read either way.
  assertEquals(parseBoolean(undefined, true), true);
  assertEquals(parseBoolean("maybe", true), true);
  assertEquals(parseBoolean("maybe", false), false);
});
