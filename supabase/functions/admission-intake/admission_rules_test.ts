import {
  feePlanMentionFromMessages,
  normalizeAdmissionPlan,
  removeResolvedBlankFormPaymentConflicts,
  shouldUseMediaAsPaymentProof,
} from "./admission_rules.ts";

Deno.test("natural staff payment wording deterministically selects the plan", () => {
  const quarterly = feePlanMentionFromMessages([
    { text_body: "New admission" },
    { text_body: "Paid 3 months" },
  ]);
  if (quarterly?.plan !== "quarterly" || quarterly.months !== 3) {
    throw new Error(`Unexpected quarterly plan: ${JSON.stringify(quarterly)}`);
  }
  const corrected = feePlanMentionFromMessages([
    { text_body: "Paid 3 months" },
    { text_body: "Fee plan 6 months" },
  ]);
  if (corrected?.plan !== "halfyearly" || corrected.months !== 6) {
    throw new Error(`Later plan correction did not win: ${JSON.stringify(corrected)}`);
  }
});

Deno.test("special training keeps its natural month counter", () => {
  const special = feePlanMentionFromMessages([{ text_body: "Special training for 4 months" }]);
  if (special?.plan !== "special" || special.months !== 4) {
    throw new Error(`Unexpected special plan: ${JSON.stringify(special)}`);
  }
});

Deno.test("three-month admission instructions normalize to quarterly", () => {
  const draft = normalizeAdmissionPlan({ fee_plan: "pending", months_covered: 3 });
  if (draft.fee_plan !== "quarterly" || draft.months_covered !== 3) {
    throw new Error(`Unexpected normalized plan: ${JSON.stringify(draft)}`);
  }
});

Deno.test("staff payment date resolves a blank form-date conflict", () => {
  const conflicts = removeResolvedBlankFormPaymentConflicts([
    "Chat says paid 3 months / 10k, while form has no filled FEE Paid on date.",
    "A different unresolved conflict.",
  ], "2026-07-16");
  if (conflicts.length !== 1 || conflicts[0] !== "A different unresolved conflict.") {
    throw new Error(`Unexpected conflicts: ${JSON.stringify(conflicts)}`);
  }
});

Deno.test("admission form media is not payment proof", () => {
  if (shouldUseMediaAsPaymentProof("admission", "form_date_only")) {
    throw new Error("An admission form must not be promoted as payment proof.");
  }
  if (!shouldUseMediaAsPaymentProof("admission", "payment_screenshot")) {
    throw new Error("A classified payment screenshot should remain proof.");
  }
  if (!shouldUseMediaAsPaymentProof("renewal", "payment_screenshot")) {
    throw new Error("Renewal payment media should remain proof.");
  }
});

import { normalizeAgeAndDateOfBirth } from "./admission_rules.ts";

function dobCase(input: Record<string, unknown>, expected: { dob: string; age: number }) {
  const draft: Record<string, unknown> = { age: 0, join_date: "2026-08-18", ...input };
  const out = normalizeAgeAndDateOfBirth(draft);
  if (out.date_of_birth !== expected.dob || Number(out.age) !== expected.age) {
    throw new Error(
      `${JSON.stringify(input)} -> dob=${out.date_of_birth} age=${out.age}, ` +
        `expected dob=${expected.dob} age=${expected.age}`,
    );
  }
}

Deno.test("an age written in the date-of-birth box becomes the age", () => {
  // KARTHIK - WUYYURU: the parent wrote 11 where the date belongs.
  dobCase({ date_of_birth: "11" }, { dob: "", age: 11 });
  dobCase({ date_of_birth: " 11 years " }, { dob: "", age: 11 });
  dobCase({ date_of_birth: "7" }, { dob: "", age: 7 });
});

Deno.test("a birth year on its own gives an age, never an invented date", () => {
  dobCase({ date_of_birth: "2015" }, { dob: "", age: 11 });
  // The day and month are not knowable, so no date of birth is stored.
});

Deno.test("a real date of birth is left untouched", () => {
  dobCase({ date_of_birth: "2015-07-08" }, { dob: "2015-07-08", age: 0 });
});

Deno.test("an age the form already gave is never overwritten", () => {
  // The age box wins; the date box only fills a gap.
  dobCase({ date_of_birth: "11", age: 9 }, { dob: "", age: 9 });
});

Deno.test("something that is neither a date nor an age is cleared", () => {
  // Storing a half-parsed string as a date of birth is worse than storing
  // nothing: the intake will simply ask for what is missing.
  dobCase({ date_of_birth: "n/a" }, { dob: "", age: 0 });
  dobCase({ date_of_birth: "--" }, { dob: "", age: 0 });
  dobCase({ date_of_birth: "1899" }, { dob: "", age: 0 });
});

Deno.test("an empty date-of-birth box changes nothing", () => {
  dobCase({ date_of_birth: "" }, { dob: "", age: 0 });
});
