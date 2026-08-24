/**
 * Parents do not always put a date in the date-of-birth box. On the paper
 * form it is one line, and what actually arrives is any of:
 *
 *   "11"          the child's age, written where the date belongs
 *   "2015"        the birth YEAR only
 *   "11 years"    the age, spelled out
 *   "2015-07-08"  an actual date of birth
 *
 * KARTHIK - WUYYURU came through as the first of these. The extractor put 11
 * in the age field and left date_of_birth empty, which was right — but it is
 * the model's judgement each time, and the same box could just as easily
 * arrive as a date-shaped string that is not a date. This decides it in code,
 * so the same input always lands the same way.
 *
 * Only ever moves a value out of date_of_birth. It will not overwrite an age
 * the form already gave, and it will not invent a date of birth from an age —
 * the day and month are not knowable, and a made-up one would be indexed,
 * displayed and eventually believed.
 */
export function normalizeAgeAndDateOfBirth<T extends Record<string, any>>(draft: T): T {
  const normalized: Record<string, any> = draft || {};
  const raw = String(normalized.date_of_birth ?? "").trim();
  if (!raw) return normalized as T;

  // A real date is left exactly as it is.
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) return normalized as T;

  const statedAge = Number(normalized.age || 0);
  const digits = raw.match(/\d+/g) || [];

  // "11" or "11 years" — an age in the wrong box.
  if (digits.length === 1 && digits[0].length <= 2) {
    const age = Number(digits[0]);
    if (age >= 3 && age <= 25) {
      normalized.date_of_birth = "";
      if (!statedAge) normalized.age = age;
      return normalized as T;
    }
  }

  // "2015" — a birth year on its own. An age is derivable; a date is not.
  if (digits.length === 1 && digits[0].length === 4) {
    const year = Number(digits[0]);
    const reference = /^\d{4}-\d{2}-\d{2}$/.test(String(normalized.join_date || ""))
      ? Number(String(normalized.join_date).slice(0, 4))
      : new Date().getUTCFullYear();
    const age = reference - year;
    if (age >= 3 && age <= 25) {
      normalized.date_of_birth = "";
      if (!statedAge) normalized.age = age;
      return normalized as T;
    }
  }

  // Anything else in that box is not a date and not an age. Clearing it is
  // the honest outcome: a half-parsed string stored as a date of birth is
  // worse than no date of birth, and the intake will ask for what is missing.
  normalized.date_of_birth = "";
  return normalized as T;
}

export function normalizeAdmissionPlan<T extends Record<string, any>>(draft: T): T {
  const normalized: Record<string, any> = draft || {};
  const aliases: Record<string, string> = {
    "1month": "monthly",
    "1months": "monthly",
    "one month": "monthly",
    "3month": "quarterly",
    "3months": "quarterly",
    "three months": "quarterly",
    "6month": "halfyearly",
    "6months": "halfyearly",
    "six months": "halfyearly",
  };
  const rawPlan = String(normalized.fee_plan || "").toLowerCase().trim();
  const compactPlan = rawPlan.replace(/\s+/g, "");
  normalized.fee_plan = aliases[rawPlan] || aliases[compactPlan] || rawPlan;
  const months = Number(normalized.months_covered || 0);
  const planByMonths: Record<number, string> = { 1: "monthly", 3: "quarterly", 6: "halfyearly" };
  if (
    planByMonths[months] &&
    !["monthly", "quarterly", "halfyearly", "special", "custom"].includes(normalized.fee_plan)
  ) {
    normalized.fee_plan = planByMonths[months];
  }
  if (normalized.fee_plan === "monthly") normalized.months_covered = 1;
  if (normalized.fee_plan === "quarterly") normalized.months_covered = 3;
  if (normalized.fee_plan === "halfyearly") normalized.months_covered = 6;
  return normalized as T;
}

export type ConversationFeePlan = {
  plan: "monthly" | "quarterly" | "halfyearly" | "special";
  months: number;
  source: string;
};

export function feePlanMentionFromMessages(
  messages: Array<{ text_body?: unknown }>,
): ConversationFeePlan | null {
  let selected: ConversationFeePlan | null = null;
  for (const message of messages || []) {
    const source = String(message?.text_body || "").trim();
    if (!source) continue;
    const text = source.toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ");
    const hasPlanContext = /\b(?:fee|fees|plan|paid|pay|payment|register|renew|renewal|training)\b/.test(text);
    if (!hasPlanContext) continue;

    const special = text.match(/\bspecial(?: training| coaching)?(?:\s+(?:for|plan|paid))?\s*(\d{1,2})?\s*months?\b/) ||
      text.match(/\b(\d{1,2})\s*months?\s+special(?: training| coaching)?\b/);
    if (special) {
      const months = Math.min(36, Math.max(1, Number(special[1] || 1)));
      selected = { plan: "special", months, source };
      continue;
    }
    if (/\b(?:6|six)\s*months?\b|\bhalf\s*yearly\b/.test(text)) {
      selected = { plan: "halfyearly", months: 6, source };
      continue;
    }
    if (/\b(?:3|three)\s*months?\b|\bquarterly\b/.test(text)) {
      selected = { plan: "quarterly", months: 3, source };
      continue;
    }
    if (/\b(?:1|one)\s*months?\b|\bmonthly\b/.test(text)) {
      selected = { plan: "monthly", months: 1, source };
    }
  }
  return selected;
}

export function removeResolvedBlankFormPaymentConflicts(
  conflicts: unknown[],
  paymentDate: unknown,
): string[] {
  const values = (conflicts || []).map((value) => String(value)).filter(Boolean);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(paymentDate || ""))) return values;
  return values.filter((conflict) =>
    !/(?:chat|staff).*(?:while|but).*(?:form).*(?:no|blank|empty|not filled).*(?:fee|paid|payment|date)|form.*(?:no|blank|empty|not filled).*(?:fee|paid|payment|date)/i.test(conflict)
  );
}

export function shouldUseMediaAsPaymentProof(
  intakeType: string,
  evidenceType: string,
): boolean {
  return intakeType === "renewal" || evidenceType === "payment_screenshot";
}
