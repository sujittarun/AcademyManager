import {
  isCoachingFeePayment,
  monthsForPlan,
  normalizeSelectedPlan,
  parseReminderReplyPayload,
  paymentAmountForReminderType,
} from "./payment_plans.ts";

Deno.test("only joining and renewal payments extend coaching coverage", () => {
  for (const paymentType of ["joining", "renewal", " Renewal "]) {
    if (!isCoachingFeePayment({ payment_type: paymentType })) {
      throw new Error(`${paymentType} should extend coaching coverage.`);
    }
  }

  for (const paymentType of ["jersey", "jersey_refund", "expense", "", null]) {
    if (isCoachingFeePayment({ payment_type: paymentType })) {
      throw new Error(`${paymentType} must not extend coaching coverage.`);
    }
  }
});

Deno.test("special training uses the admission discount schedule", () => {
  const expected = new Map([[1, 10000], [2, 20000], [3, 28500], [6, 54000]]);
  for (const [months, amount] of expected) {
    const actual = paymentAmountForReminderType("renewal", "special", months);
    if (actual !== amount) throw new Error(`${months} months: expected ${amount}, got ${actual}`);
  }
});

Deno.test("special training does not add the joining fee", () => {
  const actual = paymentAmountForReminderType("joining_fee", "special", 1);
  if (actual !== 10000) throw new Error(`Expected 10000, got ${actual}`);
});

Deno.test("special training aliases and month bounds normalize safely", () => {
  if (normalizeSelectedPlan("Special Training") !== "special") {
    throw new Error("Special Training label did not normalize.");
  }
  if (monthsForPlan("special", 0) !== 1 || monthsForPlan("special", 99) !== 36) {
    throw new Error("Special Training month bounds are incorrect.");
  }
});

Deno.test("legacy sample reminder callbacks remain isolated from live events", () => {
  const parsed = parseReminderReplyPayload(
    "renewal:sample-2ea4ff29-c0ba-4ddf-9234-35003c082cda:monthly",
  );
  if (!parsed.isReminderReply || !parsed.isSample) {
    throw new Error("Sample reminder callback was not recognized.");
  }
  if (parsed.plan !== "monthly") {
    throw new Error(`Expected monthly, got ${parsed.plan}`);
  }
});

Deno.test("live reminder callbacks and ordinary intake text stay distinct", () => {
  const live = parseReminderReplyPayload(
    "renewal:2a9ea5f7-4844-4263-922c-cfbb1d66420a:quarterly",
  );
  if (!live.isReminderReply || live.isSample || live.plan !== "quarterly") {
    throw new Error("Live reminder callback routing is incorrect.");
  }

  const intake = parseReminderReplyPayload("Veekshith 1 month renewal");
  if (intake.isReminderReply || intake.eventId || intake.plan) {
    throw new Error("Ordinary AgentAlpha text was treated as a reminder button.");
  }
});
