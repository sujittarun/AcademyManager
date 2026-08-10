const ACTIVE_PAYMENT_STATUSES = new Set([
  "payment_attempted",
  "payment_pending_verification",
]);

function timestamp(value: unknown): number {
  const parsed = Date.parse(String(value || ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function paymentActivityAt(reminder: Record<string, unknown>): number {
  return Math.max(
    timestamp(reminder.payment_pending_verification_at),
    timestamp(reminder.payment_attempted_at),
    timestamp(reminder.manager_payment_alert_due_at),
    timestamp(reminder.created_at),
  );
}

/**
 * Parent proof often arrives without a WhatsApp reply context. Prefer the
 * reminder whose Pay Now conversation is active instead of the newest daily
 * reminder row, which may have been created after the parent opened payment.
 */
export function selectPaymentConversationReminder(
  reminders: Record<string, unknown>[],
): Record<string, unknown> | null {
  if (!reminders.length) return null;

  const active = reminders.filter((reminder) =>
    ACTIVE_PAYMENT_STATUSES.has(String(reminder.status || "")) ||
    String(reminder.manager_payment_alert_status || "") === "scheduled"
  );
  const candidates = active.length ? active : reminders;
  return [...candidates].sort((left, right) =>
    paymentActivityAt(right) - paymentActivityAt(left)
  )[0] || null;
}

export function buildManagerAttemptNoProofMessage(playerName: string): string {
  return [
    "Payment attempt — proof not received yet.",
    "",
    `Player: ${playerName || "Unknown player"}`,
    "The parent opened Pay Now, but no Paid reply or payment proof has been received.",
    "Please wait for proof before confirming payment.",
  ].join("\n");
}

export function buildManagerPaymentClaimMessage(playerName: string): string {
  return [
    "Parent reported that payment was completed — screenshot not submitted.",
    "",
    `Player: ${playerName || "Unknown player"}`,
    "Please verify the payment before confirming it in the app.",
  ].join("\n");
}
