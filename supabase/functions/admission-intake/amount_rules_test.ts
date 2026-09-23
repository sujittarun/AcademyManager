import {
  inferRenewalPlanFromAmount,
  reconcileAdmissionAmount,
  reconcileRenewalAmount,
} from "./amount_rules.ts";

// A ₹3,500 family: the family's quote and the list agree.
const LIST_FAMILY = { monthly: [3500, 3500], quarterly: [9975, 9975], halfyearly: [18900, 18900] };
// A ₹3,000 family: quote_fee says 3,000 / 9,000, the list still says 3,500 / 9,975.
const DISCOUNT_FAMILY = { monthly: [3000, 3500], quarterly: [9000, 9975], halfyearly: [18000, 18900] };
const LIST = { coaching: 3500, admissionFee: 500 };

function renewal(plan: string, amount: number, months = 0) {
  return { plan_type: plan, months_covered: months, payment: { amount } };
}
function admission(plan: string, amount: number, extra: Record<string, unknown> = {}) {
  return { fee_plan: plan, months_covered: 0, custom_coaching_fee: 0, jersey_pairs: 0, payment: { amount }, ...extra };
}
function expect(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("a renewal at a price that is not the plan's price is custom for the plan's months", () => {
  // 18 Sep, Tejith: "1 month renewal", screenshot for ₹3,000, family rate ₹3,500.
  const draft = renewal("monthly", 3000, 1);
  const note = reconcileRenewalAmount(draft, LIST_FAMILY);
  expect(note.changed, "₹3,000 against a ₹3,500 monthly rate must become custom");
  expect(draft.plan_type === "custom" && draft.months_covered === 1, `got ${draft.plan_type}/${draft.months_covered}`);
  expect(/3,000/.test(note.note) && /3,500/.test(note.note), `note must say both amounts: ${note.note}`);

  // ₹7,000 on "monthly" (3 Sep, Aarav C): accepted, custom, one month — the owner reads the review.
  const big = renewal("monthly", 7000, 1);
  expect(reconcileRenewalAmount(big, LIST_FAMILY).changed && big.plan_type === "custom", "₹7,000 is accepted as custom");

  // Quarterly at ₹9,000 is a custom three months.
  const quarter = renewal("quarterly", 9000, 3);
  reconcileRenewalAmount(quarter, LIST_FAMILY);
  expect(quarter.plan_type === "custom" && quarter.months_covered === 3, "quarterly keeps its three months");
});

Deno.test("a renewal at the plan's price — the family's or the list's — keeps its plan", () => {
  const list = renewal("monthly", 3500, 1);
  expect(!reconcileRenewalAmount(list, LIST_FAMILY).changed && list.plan_type === "monthly", "₹3,500 stays monthly");

  // A family already on ₹3,000 renewing at ₹3,000 is not "custom": that IS their monthly.
  const family = renewal("monthly", 3000, 1);
  expect(!reconcileRenewalAmount(family, DISCOUNT_FAMILY).changed && family.plan_type === "monthly", "a ₹3,000 family at ₹3,000 stays monthly");

  // The same family paying the list ₹3,500 is also not custom.
  const atList = renewal("monthly", 3500, 1);
  expect(!reconcileRenewalAmount(atList, DISCOUNT_FAMILY).changed, "the list price is always a plan price");

  // Quarterly at the family's ₹9,000 stays quarterly.
  const quarter = renewal("quarterly", 9000, 3);
  expect(!reconcileRenewalAmount(quarter, DISCOUNT_FAMILY).changed, "₹9,000 is this family's quarterly");
});

Deno.test("special, custom and unpriced renewals are left alone", () => {
  const special = renewal("special", 10000, 1);
  expect(!reconcileRenewalAmount(special, LIST_FAMILY).changed && special.plan_type === "special", "special has its own ladder");
  const custom = renewal("custom", 2750, 1);
  expect(!reconcileRenewalAmount(custom, LIST_FAMILY).changed, "custom is already custom");
  // The price lookups failed: nothing to judge against, so accept as stated.
  const blind = renewal("monthly", 3000, 1);
  expect(!reconcileRenewalAmount(blind, {}).changed && blind.plan_type === "monthly", "no prices → plan stands");
  const zero = renewal("monthly", 0, 1);
  expect(!reconcileRenewalAmount(zero, LIST_FAMILY).changed, "no amount → nothing to reconcile");
});

Deno.test("an amount that is a plan price names the plan when the model named none", () => {
  const d = renewal("", 3500);
  const inferred = inferRenewalPlanFromAmount(d, "", LIST_FAMILY);
  expect(inferred?.plan_type === "monthly" && d.months_covered === 1, "₹3,500 → monthly");
  const q = renewal("", 9000);
  expect(inferRenewalPlanFromAmount(q, "", DISCOUNT_FAMILY)?.plan_type === "quarterly", "₹9,000 → this family's quarterly");
  // A monthly player paying ₹9,000 with no months stated: do not guess three; the review asks.
  expect(inferRenewalPlanFromAmount(renewal("", 9000), "monthly", DISCOUNT_FAMILY) === null, "the current plan outranks an inference");
  // The player's current plan disagrees: do not guess.
  const disagree = renewal("", 3500);
  expect(inferRenewalPlanFromAmount(disagree, "custom", LIST_FAMILY) === null, "a custom player at ₹3,500 is not silently monthly");
  // Off every price: no plan, the review asks.
  expect(inferRenewalPlanFromAmount(renewal("", 3000), "", LIST_FAMILY) === null, "₹3,000 names no plan for a ₹3,500 family");
  expect(inferRenewalPlanFromAmount(renewal("monthly", 3000), "", LIST_FAMILY) === null, "a stated plan is never overridden");
});

Deno.test("an admission at the list price, with or without the admission fee, keeps its plan", () => {
  const four = admission("monthly", 4000);
  expect(!reconcileAdmissionAmount(four, LIST).changed && four.fee_plan === "monthly", "₹4,000 = 3,500 + 500 stays monthly");
  const three5 = admission("monthly", 3500);
  expect(!reconcileAdmissionAmount(three5, LIST).changed && three5.fee_plan === "monthly", "₹3,500 (fee waived) stays monthly");
  // One jersey pair on top of the full fee is still a monthly admission.
  const jersey = admission("monthly", 4750, { jersey_pairs: 1 });
  expect(!reconcileAdmissionAmount(jersey, LIST).changed, "₹4,750 = 3,500 + 500 + 750 jersey stays monthly");
});

Deno.test("an admission at any other amount is custom at that amount", () => {
  const d = admission("monthly", 4750);
  const note = reconcileAdmissionAmount(d, LIST);
  expect(note.changed && d.fee_plan === "custom", "₹4,750 with no jersey is custom");
  expect(d.custom_coaching_fee === 4750 && d.months_covered === 1, `coaching must be the amount: ${d.custom_coaching_fee}/${d.months_covered}`);

  const low = admission("monthly", 3000);
  reconcileAdmissionAmount(low, LIST);
  expect(low.fee_plan === "custom" && low.custom_coaching_fee === 3000, "₹3,000 is custom at ₹3,000");

  // 16 Jul: ₹10,000 "quarterly" against 9,975 + 500 — custom for three months.
  const q = admission("quarterly", 10000);
  reconcileAdmissionAmount(q, { coaching: 9975, admissionFee: 500 });
  expect(q.fee_plan === "custom" && q.months_covered === 3 && q.custom_coaching_fee === 10000, "₹10,000 quarterly is custom for 3 months");

  // The jersey is merchandise, not coaching: it comes off before the fee is set.
  const withKit = admission("monthly", 5500, { jersey_pairs: 1 });
  reconcileAdmissionAmount(withKit, LIST);
  expect(withKit.fee_plan === "custom" && withKit.custom_coaching_fee === 4750, `kit must come off: ${withKit.custom_coaching_fee}`);
});

Deno.test("a custom or unpriced admission is completed, never overridden", () => {
  // The model said custom but left the fee blank: the amount is the fee.
  const blank = admission("custom", 4200);
  expect(reconcileAdmissionAmount(blank, LIST).changed && blank.custom_coaching_fee === 4200, "a blank custom fee is filled from the amount");
  const set = admission("custom", 4200, { custom_coaching_fee: 4000 });
  expect(!reconcileAdmissionAmount(set, LIST).changed && set.custom_coaching_fee === 4000, "a stated custom fee stands");
  const special = admission("special", 10000);
  expect(!reconcileAdmissionAmount(special, LIST).changed, "special has its own ladder");
  const pending = admission("pending", 0);
  expect(!reconcileAdmissionAmount(pending, LIST).changed, "nothing paid, nothing to reconcile");
  const blind = admission("monthly", 3000);
  expect(!reconcileAdmissionAmount(blind, null).changed && blind.fee_plan === "monthly", "no list → plan stands");
});
