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
