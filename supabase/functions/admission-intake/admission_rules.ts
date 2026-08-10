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
