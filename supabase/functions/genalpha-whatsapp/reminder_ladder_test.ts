// The ladder must land on the same rung whatever time of day it runs.
//
// It did not. getDaysSinceDate() parsed the due date as midnight in the
// runtime's timezone (UTC on Supabase) and subtracted the current
// instant, so between 00:00 and 05:30 IST every rung read one day early
// and families due today matched no branch at all. The daily job runs at
// 15:00 IST where the two agree, which is why it survived; the 5-minutely
// retry runs through the bad window every night.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

function localIsoDate(date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Kolkata",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

// Mirrors index.ts. Kept in step by the "no clock in the answer" test below.
function getDaysSinceDate(dateValue: string, now = new Date()): number {
  if (!dateValue) return 0;
  const MS_PER_DAY = 86_400_000;
  const todayIst = Date.parse(`${localIsoDate(now)}T00:00:00Z`);
  const target = Date.parse(`${String(dateValue).slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(target)) return 0;
  return Math.round((todayIst - target) / MS_PER_DAY);
}

function rung(days: number): string {
  if (days === -2) return "heads_up";
  if (days === 0) return "renewal_day";
  if (days >= 15) return "manual_followup";
  if (days === 3 || days === 5 || (days >= 7 && days <= 14)) return "renewal";
  return "none";
}

// 00:01 IST, 05:29 IST (the last minute of the old bug's window),
// 15:00 IST when the cron fires, and 23:59 IST.
const INSTANTS: Array<[string, Date]> = [
  ["00:01 IST", new Date("2026-08-10T18:31:00Z")],
  ["05:29 IST", new Date("2026-08-10T23:59:00Z")],
  ["15:00 IST", new Date("2026-08-11T09:30:00Z")],
  ["23:59 IST", new Date("2026-08-11T18:29:00Z")],
];

const CASES: Array<[string, number, string]> = [
  ["2026-08-13", -2, "heads_up"],
  ["2026-08-11", 0, "renewal_day"],
  ["2026-08-08", 3, "renewal"],
  ["2026-08-06", 5, "renewal"],
  ["2026-08-04", 7, "renewal"],
  ["2026-07-29", 13, "renewal"],
  ["2026-07-27", 15, "manual_followup"],
];

for (const [label, now] of INSTANTS) {
  for (const [due, expectedDays, expectedRung] of CASES) {
    Deno.test(`${label}: ${due} is day ${expectedDays} (${expectedRung})`, () => {
      const d = getDaysSinceDate(due, now);
      assertEquals(d, expectedDays);
      assertEquals(rung(d), expectedRung);
    });
  }
}

// The property that actually failed: the answer must not depend on the
// clock, only on the IST calendar date.
Deno.test("the same IST day gives the same answer at any hour", () => {
  const answers = INSTANTS
    .filter(([, n]) => localIsoDate(n) === "2026-08-11")
    .map(([, n]) => getDaysSinceDate("2026-08-11", n));
  assertEquals(new Set(answers).size, 1);
  assertEquals(answers[0], 0);
});
