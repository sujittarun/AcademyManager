import {
  aggregateWhatsappMonthlyStats,
  whatsappStatsMonthKeys,
} from "./monthly_stats.ts";

Deno.test("monthly stats dedupe Meta callbacks and attribute reminder payments", () => {
  const reminder = "reminder-1";
  const result = aggregateWhatsappMonthlyStats([
    { student_id: "student-1", reminder_event_id: reminder, event_type: "direct_payment_reminder_sent", direction: "outbound", message_id: "wamid-1", status: "accepted", status_at: "2026-07-01T18:29:55Z" },
    { student_id: "student-1", reminder_event_id: reminder, event_type: "reminder_message_status", direction: "provider", message_id: "wamid-1", status: "sent", status_at: "2026-07-01T18:30:01Z" },
    { student_id: "student-1", reminder_event_id: reminder, event_type: "reminder_message_status", direction: "provider", message_id: "wamid-1", status: "delivered", status_at: "2026-07-01T18:31:00Z" },
    { student_id: "student-1", reminder_event_id: reminder, event_type: "reminder_message_status", direction: "provider", message_id: "wamid-1", status: "read", status_at: "2026-07-01T18:32:00Z" },
    { student_id: "student-1", reminder_event_id: reminder, event_type: "payment_attempted", status_at: "2026-07-02T10:00:00Z" },
    { student_id: "student-1", reminder_event_id: reminder, event_type: "payment_pending_verification", status_at: "2026-07-02T10:01:00Z", proof_path: "proof.jpg" },
    { student_id: "student-1", reminder_event_id: reminder, event_type: "payment_confirmed", status_at: "2026-07-02T10:02:00Z", payment_amount: 4000, provider_payload: {} },
  ], ["2026-07"], new Date("2026-07-10T00:00:00Z"));

  const july = result.months[0];
  if (july.remindersSent !== 1 || july.delivered !== 1 || july.read !== 1) {
    throw new Error(`Expected one deduplicated message, got ${JSON.stringify(july)}`);
  }
  if (july.paymentsViaReminder !== 1 || july.revenueViaReminder !== 4000 || july.proofSubmitted !== 1) {
    throw new Error(`Expected one attributed payment, got ${JSON.stringify(july)}`);
  }
});

Deno.test("monthly stats exclude AgentAlpha and confirmation without reminder interaction", () => {
  const result = aggregateWhatsappMonthlyStats([
    { student_id: "student-1", reminder_event_id: "agent", event_type: "payment_attempted", status_at: "2026-08-01T00:00:00Z" },
    { student_id: "student-1", reminder_event_id: "agent", event_type: "payment_confirmed", status_at: "2026-08-01T00:01:00Z", payment_amount: 5000, provider_payload: { source_payment_id: "agent-payment" } },
    { student_id: "student-2", reminder_event_id: "no-interaction", event_type: "payment_confirmed", status_at: "2026-08-01T00:01:00Z", payment_amount: 3000, provider_payload: {} },
  ], ["2026-08"], new Date("2026-08-01T02:00:00Z"));
  if (result.totals.paymentsViaReminder !== 0 || result.totals.revenueViaReminder !== 0) {
    throw new Error(`Expected non-reminder payments to be excluded, got ${JSON.stringify(result.totals)}`);
  }
});

Deno.test("month keys return the requested oldest-to-newest window", () => {
  const keys = whatsappStatsMonthKeys(4, new Date("2026-08-01T12:00:00+05:30"));
  if (keys.join(",") !== "2026-05,2026-06,2026-07,2026-08") {
    throw new Error(`Unexpected month keys: ${keys.join(",")}`);
  }
});

Deno.test("total players are unique across months", () => {
  const result = aggregateWhatsappMonthlyStats([
    { student_id: "same-student", reminder_event_id: "may-reminder", event_type: "reminder_message_status", direction: "outbound", message_id: "may-message", status: "accepted", status_at: "2026-05-10T10:00:00Z" },
    { student_id: "same-student", reminder_event_id: "june-reminder", event_type: "reminder_message_status", direction: "outbound", message_id: "june-message", status: "accepted", status_at: "2026-06-10T10:00:00Z" },
  ], ["2026-05", "2026-06"], new Date("2026-06-15T00:00:00Z"));
  if (result.months[0].playersReached !== 1 || result.months[1].playersReached !== 1 || result.totals.playersReached !== 1) {
    throw new Error(`Expected one player across the period, got ${JSON.stringify(result)}`);
  }
});
