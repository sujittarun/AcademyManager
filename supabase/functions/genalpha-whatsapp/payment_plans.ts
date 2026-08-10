export const PLAN_OPTIONS = ["monthly", "quarterly", "halfyearly", "special", "need_help"];

export const PLAN_LABELS: Record<string, string> = {
  monthly: "1 Month",
  quarterly: "3 Months",
  halfyearly: "6 Months",
  special: "Special Training",
  need_help: "Need Help",
};

export const PLAN_AMOUNTS: Record<string, number> = {
  monthly: 3500,
  quarterly: 9975,
  halfyearly: 18900,
  special: 10000,
};

export const PLAN_MONTHS: Record<string, number> = {
  monthly: 1,
  quarterly: 3,
  halfyearly: 6,
  special: 1,
};

export const PAID_PLAN_OPTIONS = PLAN_OPTIONS.filter((plan) => plan !== "need_help");
export const SPECIAL_TRAINING_MONTHLY_FEE = 10000;
export const SAMPLE_REMINDER_EVENT_PREFIX = "sample-";

export function isCoachingFeePayment(payment: Record<string, unknown>): boolean {
  const paymentType = String(
    payment?.payment_type || payment?.paymentType || "",
  ).trim().toLowerCase();
  return paymentType === "joining" || paymentType === "renewal";
}

export function parseReminderReplyPayload(value: unknown): {
  isReminderReply: boolean;
  isSample: boolean;
  eventId: string;
  plan: string;
} {
  const payload = String(value || "");
  if (!payload.startsWith("renewal:")) {
    return {
      isReminderReply: false,
      isSample: false,
      eventId: "",
      plan: "",
    };
  }

  const [, eventId = "", plan = ""] = payload.split(":");
  return {
    isReminderReply: Boolean(eventId),
    isSample: eventId.startsWith(SAMPLE_REMINDER_EVENT_PREFIX),
    eventId,
    plan,
  };
}

export function getSpecialTrainingDiscountRate(months: number): number {
  const safeMonths = Math.max(Math.floor(Number(months || 1)), 1);
  if (safeMonths >= 6) return 0.1;
  if (safeMonths >= 3) return 0.05;
  return 0;
}

export function getSpecialTrainingAmountForMonths(months: number): number {
  const safeMonths = Math.max(Math.floor(Number(months || 1)), 1);
  return Math.round(
    SPECIAL_TRAINING_MONTHLY_FEE * safeMonths *
      (1 - getSpecialTrainingDiscountRate(safeMonths)),
  );
}

export function inferSpecialTrainingMonthsFromAmount(amount: number): number {
  const roundedAmount = Math.round(Number(amount || 0));
  if (roundedAmount <= 0) return 1;
  for (let months = 1; months <= 36; months += 1) {
    if (getSpecialTrainingAmountForMonths(months) === roundedAmount) return months;
  }
  if (roundedAmount >= getSpecialTrainingAmountForMonths(6)) {
    return Math.max(
      Math.round(roundedAmount / (SPECIAL_TRAINING_MONTHLY_FEE * 0.9)),
      1,
    );
  }
  if (roundedAmount >= getSpecialTrainingAmountForMonths(3)) {
    return Math.max(
      Math.round(roundedAmount / (SPECIAL_TRAINING_MONTHLY_FEE * 0.95)),
      1,
    );
  }
  return Math.max(Math.round(roundedAmount / SPECIAL_TRAINING_MONTHLY_FEE), 1);
}

export function normalizeChoiceText(value: unknown): string {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

export function normalizeSelectedPlan(value: unknown): string {
  const normalized = normalizeChoiceText(value);
  if (["monthly", "month", "1month", "one1month", "onemonth", "1"].includes(normalized)) {
    return "monthly";
  }
  if (["quarterly", "3month", "3months", "threemonths", "3"].includes(normalized)) {
    return "quarterly";
  }
  if (["halfyearly", "6month", "6months", "sixmonths", "6"].includes(normalized)) {
    return "halfyearly";
  }
  if (["special", "specialtraining", "personaltraining", "specialcoaching"].includes(normalized)) {
    return "special";
  }
  if (["needhelp", "help", "support"].includes(normalized)) return "need_help";
  return "";
}

export function monthsForPlan(plan: string, requestedMonths: unknown = 0): number {
  if (plan === "special") {
    return Math.min(36, Math.max(1, Math.floor(Number(requestedMonths || 1))));
  }
  return PLAN_MONTHS[plan] || 0;
}

export function paymentAmountForReminderType(
  reminderType: string,
  plan: string,
  requestedMonths: unknown = 0,
): number {
  if (plan === "special") {
    return getSpecialTrainingAmountForMonths(monthsForPlan(plan, requestedMonths));
  }
  const baseAmount = PLAN_AMOUNTS[plan] || 0;
  return reminderType === "joining_fee" ? baseAmount + 500 : baseAmount;
}
