import {
  buildManagerAttemptNoProofMessage,
  buildManagerPaymentClaimMessage,
  selectPaymentConversationReminder,
} from "./conversation_routing.ts";

Deno.test("proof follows the active Pay Now attempt instead of a newer daily reminder", () => {
  const selected = selectPaymentConversationReminder([
    {
      id: "new-daily-reminder",
      status: "delivered",
      created_at: "2026-07-31T15:00:00+05:30",
    },
    {
      id: "active-pay-now",
      status: "payment_attempted",
      payment_attempted_at: "2026-07-31T18:29:00+05:30",
      created_at: "2026-07-28T15:00:00+05:30",
    },
  ]);

  if (selected?.id !== "active-pay-now") {
    throw new Error(
      `Expected active-pay-now, got ${String(selected?.id || "none")}`,
    );
  }
});

Deno.test("a Paid reply without an image remains an unverified parent claim", () => {
  const message = buildManagerPaymentClaimMessage("Karthikeya");
  if (!message.includes("Parent reported") || !message.includes("verify")) {
    throw new Error("The payment-claim alert is missing verification context.");
  }
  if (/payment vochindi/i.test(message)) {
    throw new Error(
      "The payment-claim alert uses the old confirmed-payment wording.",
    );
  }
});

Deno.test("latest active payment conversation wins when a parent tries twice", () => {
  const selected = selectPaymentConversationReminder([
    {
      id: "older-attempt",
      status: "payment_attempted",
      payment_attempted_at: "2026-07-31T18:00:00+05:30",
    },
    {
      id: "newer-attempt",
      status: "payment_attempted",
      payment_attempted_at: "2026-07-31T18:30:00+05:30",
    },
  ]);

  if (selected?.id !== "newer-attempt") {
    throw new Error(
      `Expected newer-attempt, got ${String(selected?.id || "none")}`,
    );
  }
});

Deno.test("ordinary replies still fall back to the newest reminder", () => {
  const selected = selectPaymentConversationReminder([
    {
      id: "older",
      status: "delivered",
      created_at: "2026-07-30T15:00:00+05:30",
    },
    {
      id: "newer",
      status: "delivered",
      created_at: "2026-07-31T15:00:00+05:30",
    },
  ]);

  if (selected?.id !== "newer") {
    throw new Error(`Expected newer, got ${String(selected?.id || "none")}`);
  }
});

Deno.test("a Pay Now click without proof is described as an attempt, not a payment", () => {
  const message = buildManagerAttemptNoProofMessage("Karthikeya");
  if (
    !message.includes("proof not received yet") ||
    !message.includes("opened Pay Now")
  ) {
    throw new Error("The soft manager alert is missing attempt/proof context.");
  }
  if (/payment (?:received|confirmed)|payment vochindi/i.test(message)) {
    throw new Error(
      "The soft manager alert falsely claims payment was received.",
    );
  }
});
