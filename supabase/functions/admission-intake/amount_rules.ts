/**
 * THE FAMILY PAYS WHAT THEY PAID.
 *
 * "for renewals or admissions accept whatever amount mentioned and update
 *  same in the app like custom amount. admissions sometimes we get 4000
 *  sometimes 3500; renewals sometimes 2500, sometimes 3500, and in between"
 *
 * The agent used to carry its own price list — 3,500 / 9,975 / 18,900 — and
 * any renewal that did not land on it became a conflict nobody could
 * resolve: "Payment amount Rs 3,000 does not match the monthly academy
 * price of Rs 3,500." Four reviews hit that wall (10 Aug, 3 Sep, 4 Sep,
 * 18 Sep); all four expired and the owner entered them by hand. In the
 * same sixty days 15 of the 56 renewals recorded in the app were not at
 * list price at all: 2,500, 3,000, 4,750.
 *
 * Prices are not this function's to know. They come from the database —
 * quote_fee() for what THIS family pays, resolve_fee() for the academy
 * list — and are handed in here as plain numbers, so the rules run on the
 * desk with no database and no model.
 *
 * The rule is the one the app already has. An amount that matches a plan
 * is that plan. Any other amount is the app's "custom" plan at that
 * amount, for the months the staff said. Nothing is refused for its size;
 * the review states what it did and the owner still confirms.
 *
 * Custom follows the app's own convention (ten students carry it today):
 * coaching_fee is the amount paid, the ₹500 admission line stays nominal,
 * and approve_admission turns coaching_fee / months into the family's
 * monthly rate — which is exactly "update same in the app".
 */

export const STANDARD_PLAN_MONTHS: Record<string, number> = { monthly: 1, quarterly: 3, halfyearly: 6 };

/** plan -> every price that counts as "that plan": the family's own quote and the list. */
export type PlanPrices = Record<string, number[]>;

export type ListPrice = { coaching: number; admissionFee: number };

export type AmountNote = { changed: boolean; note: string };

const UNCHANGED: AmountNote = { changed: false, note: "" };

function rupees(value: number): string {
  return `₹${Number(value).toLocaleString("en-IN")}`;
}

function monthsLabel(months: number): string {
  return `${months} month${months === 1 ? "" : "s"}`;
}

function matchesAny(amount: number, prices: number[] | undefined): boolean {
  return (prices || []).some((price) => Number.isFinite(price) && price > 0 && Math.abs(amount - price) < 0.01);
}

/**
 * When the model named no plan, an amount that IS a plan price names it.
 * Replaces the hardcoded table this used to carry; same behaviour, prices
 * from outside.
 */
export function inferRenewalPlanFromAmount(
  draft: Record<string, any>,
  existingPlan: string,
  prices: PlanPrices,
): { plan_type: string; months_covered: number; source: string } | null {
  const validPlans = ["monthly", "quarterly", "halfyearly", "special", "custom"];
  if (validPlans.includes(String(draft?.plan_type || "").toLowerCase())) return null;
  const amount = Number(draft?.payment?.amount || 0);
  if (!(amount > 0)) return null;
  const inferred = Object.entries(STANDARD_PLAN_MONTHS).find(([plan]) => matchesAny(amount, prices[plan]));
  if (!inferred) return null;
  const [planType, months] = inferred;
  const current = String(existingPlan || "").toLowerCase();
  if (current && validPlans.includes(current) && current !== planType) return null;
  draft.plan_type = planType;
  draft.months_covered = months;
  return {
    plan_type: planType,
    months_covered: months,
    source: `Amount ${rupees(amount)} is the ${planType} price${current ? " and the player's current plan" : ""}`,
  };
}

/**
 * A renewal at a price that is not the plan's price is a custom renewal for
 * the plan's months. The family's own rate counts as the plan's price, so a
 * ₹3,000 family renewing at ₹3,000 stays "monthly"; a ₹3,500 family paying
 * ₹3,000 becomes "custom, 1 month" and the review says so.
 */
export function reconcileRenewalAmount(draft: Record<string, any>, prices: PlanPrices): AmountNote {
  const plan = String(draft?.plan_type || "").toLowerCase();
  const months = STANDARD_PLAN_MONTHS[plan];
  const amount = Number(draft?.payment?.amount || 0);
  if (!months || !(amount > 0)) return UNCHANGED;
  const expected = prices[plan] || [];
  // No price known (the lookups failed): nothing to judge against, so the
  // plan stands as stated. Accepting is the safe direction here.
  if (!expected.length) return UNCHANGED;
  if (matchesAny(amount, expected)) return UNCHANGED;
  draft.plan_type = "custom";
  draft.months_covered = months;
  const rate = expected[0];
  return {
    changed: true,
    note: `Custom amount ${rupees(amount)} for ${monthsLabel(months)} (this family's ${plan} rate is ${rupees(rate)}).`,
  };
}

/**
 * An admission at a price that is not the plan's price is a custom admission
 * at that amount. The plan's price is the coaching fee for its months, with
 * or without the one-time admission fee — 4,000 and 3,500 are both a monthly
 * admission today and stay one — plus whatever jersey pairs were bought.
 * Everything else becomes custom, coaching_fee = the amount, so the family's
 * rate is what they actually paid.
 */
export function reconcileAdmissionAmount(
  draft: Record<string, any>,
  list: ListPrice | null,
  jerseyPairPrice = 750,
): AmountNote {
  const plan = String(draft?.fee_plan || "").toLowerCase();
  const amount = Number(draft?.payment?.amount || 0);
  if (!(amount > 0)) return UNCHANGED;
  const jersey = Math.max(Number(draft?.jersey_pairs || 0), 0) * jerseyPairPrice;
  const coachingPaid = Math.max(amount - jersey, 0);

  if (plan === "custom") {
    if (Number(draft?.custom_coaching_fee || 0) > 0) return UNCHANGED;
    draft.custom_coaching_fee = coachingPaid;
    return { changed: true, note: `Custom amount ${rupees(amount)} recorded as the coaching fee.` };
  }
  const months = STANDARD_PLAN_MONTHS[plan];
  if (!months || !list || !(list.coaching > 0)) return UNCHANGED;

  const withFee = list.coaching + list.admissionFee + jersey;
  const withoutFee = list.coaching + jersey;
  if (matchesAny(amount, [withFee, withoutFee])) return UNCHANGED;

  draft.fee_plan = "custom";
  draft.months_covered = months;
  draft.custom_coaching_fee = coachingPaid;
  return {
    changed: true,
    note: `Custom amount ${rupees(amount)} for ${monthsLabel(months)} (list is ${rupees(list.coaching)} + ${rupees(list.admissionFee)} admission).`,
  };
}
