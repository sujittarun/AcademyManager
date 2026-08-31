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
 * How long a Pay Now conversation stays the one a screenshot belongs to.
 *
 * A parent taps Pay Now and sends the proof minutes later, sometimes the next
 * morning. Beyond that it is not the same conversation, and the newest
 * reminder is the better match.
 *
 * Without this bound the preference below never expires. karthikeya tapped
 * Pay Now on 21 July and never finished; that reminder sat in
 * payment_attempted, and on 31 August — SIX cycles later — his screenshot was
 * welded onto it. The August reminder stayed 'delivered', so the app showed
 * "renewal overdue" instead of "pending confirmation", and confirming from
 * the app did nothing because there was no pending follow-up on the current
 * cycle. Every one of the eleven reminders sitting in an active payment
 * status was stale like this, on cycles already paid.
 */
const ACTIVE_CONVERSATION_MS = 3 * 24 * 60 * 60 * 1000;

/**
 * Parent proof often arrives without a WhatsApp reply context. Prefer the
 * reminder whose Pay Now conversation is active instead of the newest daily
 * reminder row, which may have been created after the parent opened payment —
 * but only while that conversation is still recent.
 */
export function selectPaymentConversationReminder(
  reminders: Record<string, unknown>[],
  now = Date.now(),
): Record<string, unknown> | null {
  if (!reminders.length) return null;

  const active = reminders.filter((reminder) => {
    const isActive = ACTIVE_PAYMENT_STATUSES.has(String(reminder.status || "")) ||
      String(reminder.manager_payment_alert_status || "") === "scheduled";
    if (!isActive) return false;
    const activityAt = paymentActivityAt(reminder);
    return activityAt > 0 && now - activityAt <= ACTIVE_CONVERSATION_MS;
  });
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
