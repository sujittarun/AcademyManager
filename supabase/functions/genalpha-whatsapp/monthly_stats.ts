export type WhatsappStatsEvent = {
  student_id?: string | null;
  reminder_event_id?: string | null;
  event_type?: string | null;
  direction?: string | null;
  message_id?: string | null;
  status?: string | null;
  status_at?: string | null;
  created_at?: string | null;
  payment_amount?: number | string | null;
  proof_path?: string | null;
  provider_payload?: Record<string, unknown> | null;
};

export type WhatsappMonthlyStat = {
  month: string;
  label: string;
  fullLabel: string;
  isCurrent: boolean;
  remindersSent: number;
  playersReached: number;
  delivered: number;
  read: number;
  proofSubmitted: number;
  paymentsViaReminder: number;
  revenueViaReminder: number;
  deliveryRate: number;
  readRate: number;
  conversionRate: number;
};

const TIME_ZONE = "Asia/Kolkata";
const REMINDER_SEND_TYPES = new Set([
  "reminder_message_status",
  "reminder_retry_sent",
  "direct_payment_reminder_sent",
  "direct_payment_reminder_retry_sent",
]);
const INTERACTION_TYPES = new Set([
  "parent_plan_selected",
  "payment_attempted",
  "payment_pending_verification",
]);

function monthKey(value: string | null | undefined): string {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TIME_ZONE,
    year: "numeric",
    month: "2-digit",
  }).formatToParts(date);
  const year = parts.find((part) => part.type === "year")?.value || "";
  const month = parts.find((part) => part.type === "month")?.value || "";
  return year && month ? `${year}-${month}` : "";
}

function monthLabel(key: string, long = false): string {
  const [year, month] = key.split("-").map(Number);
  return new Intl.DateTimeFormat("en-IN", {
    timeZone: TIME_ZONE,
    month: long ? "long" : "short",
    ...(long ? { year: "numeric" } : {}),
  }).format(new Date(Date.UTC(year, month - 1, 15)));
}

export function whatsappStatsMonthKeys(months = 4, now = new Date()): string[] {
  const current = monthKey(now.toISOString());
  const [year, month] = current.split("-").map(Number);
  return Array.from({ length: Math.max(1, months) }, (_, index) => {
    const date = new Date(Date.UTC(year, month - 1 - (months - 1 - index), 15));
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
  });
}

function percentage(numerator: number, denominator: number): number {
  if (!denominator) return 0;
  return Math.round((numerator / denominator) * 1000) / 10;
}

export function aggregateWhatsappMonthlyStats(
  events: WhatsappStatsEvent[],
  requestedMonths: string[],
  now = new Date(),
): { months: WhatsappMonthlyStat[]; totals: Omit<WhatsappMonthlyStat, "month" | "label" | "fullLabel" | "isCurrent"> } {
  const requested = new Set(requestedMonths);
  const currentMonth = monthKey(now.toISOString());
  const buckets = new Map(requestedMonths.map((month) => [month, {
    messageIds: new Set<string>(),
    players: new Set<string>(),
    deliveredIds: new Set<string>(),
    readIds: new Set<string>(),
    proofs: new Set<string>(),
    payments: new Set<string>(),
    revenue: 0,
  }]));

  const reminderMessages = new Map<string, {
    month: string;
    studentId: string;
    statuses: Set<string>;
  }>();
  const interactions = new Set<string>();

  for (const event of events) {
    const reminderId = String(event.reminder_event_id || "");
    const eventType = String(event.event_type || "");
    if (reminderId && INTERACTION_TYPES.has(eventType)) interactions.add(reminderId);

    if (eventType === "payment_pending_verification" && reminderId) {
      const key = monthKey(event.status_at || event.created_at);
      if (requested.has(key)) buckets.get(key)?.proofs.add(reminderId);
    }

    const messageId = String(event.message_id || "");
    if (!messageId || !REMINDER_SEND_TYPES.has(eventType)) continue;
    const status = String(event.status || "").toLowerCase();
    const key = monthKey(event.status_at || event.created_at);
    const existing = reminderMessages.get(messageId);
    if (existing) {
      if (status) existing.statuses.add(status);
      if (!existing.studentId && event.student_id) existing.studentId = String(event.student_id);
      // The outbound acceptance row is the authoritative send month. Provider
      // callbacks may arrive after midnight or in a later month.
      if (event.direction === "outbound" && key) existing.month = key;
    } else {
      reminderMessages.set(messageId, {
        month: key,
        studentId: String(event.student_id || ""),
        statuses: new Set(status ? [status] : []),
      });
    }
  }

  for (const [messageId, message] of reminderMessages) {
    if (!requested.has(message.month)) continue;
    const bucket = buckets.get(message.month);
    if (!bucket) continue;
    bucket.messageIds.add(messageId);
    if (message.studentId) bucket.players.add(message.studentId);
    if (message.statuses.has("delivered") || message.statuses.has("read")) {
      bucket.deliveredIds.add(messageId);
    }
    if (message.statuses.has("read")) bucket.readIds.add(messageId);
  }

  for (const event of events) {
    if (event.event_type !== "payment_confirmed") continue;
    const reminderId = String(event.reminder_event_id || "");
    if (!reminderId || !interactions.has(reminderId)) continue;
    if (event.provider_payload?.source_payment_id) continue; // AgentAlpha/manual renewal.
    const key = monthKey(event.status_at || event.created_at);
    const bucket = buckets.get(key);
    if (!bucket || bucket.payments.has(reminderId)) continue;
    bucket.payments.add(reminderId);
    bucket.revenue += Number(event.payment_amount || 0) || 0;
  }

  const months = requestedMonths.map((key) => {
    const bucket = buckets.get(key)!;
    const remindersSent = bucket.messageIds.size;
    const playersReached = bucket.players.size;
    const delivered = bucket.deliveredIds.size;
    const read = bucket.readIds.size;
    const paymentsViaReminder = bucket.payments.size;
    return {
      month: key,
      label: monthLabel(key),
      fullLabel: monthLabel(key, true),
      isCurrent: key === currentMonth,
      remindersSent,
      playersReached,
      delivered,
      read,
      proofSubmitted: bucket.proofs.size,
      paymentsViaReminder,
      revenueViaReminder: Math.round(bucket.revenue * 100) / 100,
      deliveryRate: percentage(delivered, remindersSent),
      readRate: percentage(read, remindersSent),
      conversionRate: percentage(paymentsViaReminder, playersReached),
    };
  });

  const totals = months.reduce((sum, month) => ({
    remindersSent: sum.remindersSent + month.remindersSent,
    playersReached: sum.playersReached + month.playersReached,
    delivered: sum.delivered + month.delivered,
    read: sum.read + month.read,
    proofSubmitted: sum.proofSubmitted + month.proofSubmitted,
    paymentsViaReminder: sum.paymentsViaReminder + month.paymentsViaReminder,
    revenueViaReminder: sum.revenueViaReminder + month.revenueViaReminder,
    deliveryRate: 0,
    readRate: 0,
    conversionRate: 0,
  }), {
    remindersSent: 0,
    playersReached: 0,
    delivered: 0,
    read: 0,
    proofSubmitted: 0,
    paymentsViaReminder: 0,
    revenueViaReminder: 0,
    deliveryRate: 0,
    readRate: 0,
    conversionRate: 0,
  });
  totals.playersReached = new Set(
    [...buckets.values()].flatMap((bucket) => [...bucket.players]),
  ).size;
  totals.deliveryRate = percentage(totals.delivered, totals.remindersSent);
  totals.readRate = percentage(totals.read, totals.remindersSent);
  totals.conversionRate = percentage(totals.paymentsViaReminder, totals.playersReached);
  totals.revenueViaReminder = Math.round(totals.revenueViaReminder * 100) / 100;
  return { months, totals };
}
