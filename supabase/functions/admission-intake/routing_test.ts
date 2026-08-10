import {
  hasExplicitNewCaseBoundary,
  isSameProcessingGeneration,
  selectRecentExpiredReviewCandidate,
  selectWaitingReviewCandidate,
  shouldContinueActiveBundle,
  shouldTargetWaitingReview,
} from "./routing.ts";

function assertRoute(
  expected: boolean,
  messageType: string,
  text: string,
  replyId = "",
) {
  const actual = shouldTargetWaitingReview(messageType, text, replyId);
  if (actual !== expected) {
    throw new Error(`Expected ${expected} for ${messageType}: ${text}; received ${actual}.`);
  }
}

Deno.test("new renewal conversation stays out of old waiting reviews", () => {
  assertRoute(false, "text", "Adil's payment");
  assertRoute(false, "text", "Renewal");
  assertRoute(false, "text", "Adil renewal for 1 month");
});

Deno.test("explicit review actions target the waiting review", () => {
  assertRoute(true, "text", "confirm");
  assertRoute(true, "text", "Yes");
  assertRoute(true, "text", "okay");
  assertRoute(true, "text", "looks good");
  assertRoute(true, "text", "cancel this admission");
  assertRoute(true, "text", "ignore paid on date, mark payment pending");
  assertRoute(true, "text", "check for student name with Adil");
  assertRoute(true, "text", "School is Sloka\nMark today as payment date and register for 3 months plan");
  assertRoute(true, "text", "Set batch to 5:30 PM and address is Jubilee Hills");
});

Deno.test("standalone media starts a case unless it replies to a review", () => {
  assertRoute(false, "image", "Paid using PhonePe UPI");
  assertRoute(true, "image", "Paid using PhonePe UPI", "wamid.review-message");
});

Deno.test("a natural confirmation selects a clearly active review", () => {
  const active = {
    id: "active",
    intake_type: "renewal",
    confirmation_message_id: "wamid.active",
    updated_at: "2026-07-16T10:16:00.000Z",
  };
  const stale = {
    id: "stale",
    intake_type: "renewal",
    confirmation_message_id: "wamid.stale",
    updated_at: "2026-07-16T10:03:00.000Z",
  };
  const orphan = {
    id: "orphan",
    intake_type: "unknown",
    confirmation_message_id: "wamid.orphan",
    updated_at: "2026-07-16T10:16:30.000Z",
  };
  const selected = selectWaitingReviewCandidate([orphan, stale, active]);
  if (selected === null || selected === "ambiguous" || selected.id !== "active") {
    throw new Error("Expected the fresh, valid renewal review to be selected.");
  }
});

Deno.test("similar open reviews remain ambiguous", () => {
  const base = {
    intake_type: "admission",
    confirmation_message_id: "wamid.review",
  };
  const close = selectWaitingReviewCandidate([
    { ...base, updated_at: "2026-07-16T10:16:00.000Z" },
    { ...base, updated_at: "2026-07-16T10:15:10.000Z" },
  ]);
  if (close !== "ambiguous") throw new Error("Close reviews must require a threaded reply.");
});

Deno.test("an explicit correction can resume a just-expired review", () => {
  const now = Date.parse("2026-07-16T13:56:00.000Z");
  const selected = selectRecentExpiredReviewCandidate([{
    id: "expired-review",
    intake_type: "admission",
    confirmation_message_id: "wamid.review",
    status: "expired",
    error_code: "session_idle_timeout",
    updated_at: "2026-07-16T13:54:00.000Z",
  }], now);
  if (selected === null || selected === "ambiguous" || selected.id !== "expired-review") {
    throw new Error("Expected the just-expired review to resume.");
  }
});

Deno.test("an old or manually ended review cannot resume", () => {
  const now = Date.parse("2026-07-16T14:10:00.000Z");
  const selected = selectRecentExpiredReviewCandidate([{
    id: "stale-review",
    intake_type: "admission",
    confirmation_message_id: "wamid.review",
    status: "expired",
    error_code: "session_idle_timeout",
    updated_at: "2026-07-16T13:54:00.000Z",
  }], now);
  if (selected !== null) throw new Error("A stale review must remain ended.");
});

Deno.test("a tiny split correction resumes the more complete expired review", () => {
  const now = Date.parse("2026-07-16T13:56:00.000Z");
  const shared = { intake_type: "admission", status: "expired", error_code: "session_idle_timeout" };
  const selected = selectRecentExpiredReviewCandidate([
    {
      ...shared,
      id: "complete-form-review",
      confirmation_message_id: "wamid.form-review",
      missing_fields: ["payment.proof_or_cash_confirmation", "fee_plan"],
      extraction_version: 1,
      updated_at: "2026-07-16T13:52:00.000Z",
    },
    {
      ...shared,
      id: "split-correction-review",
      confirmation_message_id: "wamid.correction-review",
      missing_fields: ["applicant_name", "date_of_birth", "gender", "parent_contact_no", "address", "join_date", "time_slot"],
      extraction_version: 1,
      updated_at: "2026-07-16T13:54:00.000Z",
    },
  ], now);
  if (selected === null || selected === "ambiguous" || selected.id !== "complete-form-review") {
    throw new Error("Expected the more complete form review to absorb the split correction.");
  }
});

Deno.test("late plan text rejoins an unknown review instead of starting a second session", () => {
  const joins = shouldContinueActiveBundle({
    status: "waiting_for_confirmation",
    intake_type: "unknown",
    last_message_at: "2026-07-16T14:15:00.000Z",
  }, {
    message_type: "text",
    text_body: "Paid 3 months",
  }, Date.parse("2026-07-16T14:15:40.000Z"));
  if (!joins) throw new Error("Late plan text should remain in the unknown bundle.");
});

Deno.test("late payment image rejoins an unknown review", () => {
  const joins = shouldContinueActiveBundle({
    status: "waiting_for_confirmation",
    intake_type: "unknown",
    last_message_at: "2026-07-16T14:15:00.000Z",
  }, {
    message_type: "image",
    text_body: "Image received",
  }, Date.parse("2026-07-16T14:15:45.000Z"));
  if (!joins) throw new Error("Late media should remain in the unknown bundle.");
});

Deno.test("a message arriving during model processing reopens the same bundle", () => {
  const joins = shouldContinueActiveBundle({
    status: "processing",
    intake_type: "unknown",
    last_message_at: "2026-07-16T14:15:00.000Z",
  }, {
    message_type: "text",
    text_body: "10k paid for 3 months",
  }, Date.parse("2026-07-16T14:15:25.000Z"));
  if (!joins) throw new Error("Processing must not make the bundle invisible to late messages.");
});

Deno.test("an explicit new-case boundary does not merge into a known review", () => {
  if (!hasExplicitNewCaseBoundary("AgentAlpha new admission")) {
    throw new Error("Expected an explicit AgentAlpha boundary.");
  }
  const joins = shouldContinueActiveBundle({
    status: "waiting_for_confirmation",
    intake_type: "admission",
    last_message_at: "2026-07-16T14:15:00.000Z",
  }, {
    message_type: "text",
    text_body: "AgentAlpha new admission",
  }, Date.parse("2026-07-16T14:15:25.000Z"));
  if (joins) throw new Error("A clearly marked new case must get a fresh session.");
});

Deno.test("unthreaded media does not attach to a completed known review", () => {
  const joins = shouldContinueActiveBundle({
    status: "waiting_for_confirmation",
    intake_type: "renewal",
    last_message_at: "2026-07-16T14:15:00.000Z",
  }, {
    message_type: "image",
    text_body: "",
  }, Date.parse("2026-07-16T14:15:25.000Z"));
  if (joins) throw new Error("Known reviews require WhatsApp Reply for late media proof.");
});

Deno.test("a superseded processing generation cannot publish", () => {
  const claimed = { status: "processing", updated_at: "2026-07-16T14:15:20.000Z" };
  if (!isSameProcessingGeneration(claimed, { ...claimed })) {
    throw new Error("The unchanged generation should still own the result.");
  }
  if (isSameProcessingGeneration(claimed, { status: "collecting", updated_at: "2026-07-16T14:15:30.000Z" })) {
    throw new Error("A reopened bundle must supersede the older model run.");
  }
});
