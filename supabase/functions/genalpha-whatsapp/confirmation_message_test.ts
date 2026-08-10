import {
  buildRenewalConfirmationMessage,
  PAYMENT_CONFIRMATION_TEMPLATE_BODY,
  renewalConfirmationTemplateValues,
} from "./confirmation_message.ts";

Deno.test("template and in-window renewal confirmations render the same message", () => {
  const values = {
    playerName: "Player B",
    actionText: "1 Month",
    paidThroughText: "25th Aug 2026",
    amountText: "3,500",
  };
  const parameters = renewalConfirmationTemplateValues(values);
  const renderedTemplate = parameters.reduce(
    (message, value, index) => message.replaceAll(`{{${index + 1}}}`, value),
    PAYMENT_CONFIRMATION_TEMPLATE_BODY,
  );
  const inWindowMessage = buildRenewalConfirmationMessage(values);

  if (renderedTemplate !== inWindowMessage) {
    throw new Error("Template and text confirmation bodies diverged.");
  }
  if (
    !inWindowMessage.includes("Payment Confirmed") ||
    !inWindowMessage.includes("Amount received: Rs 3,500")
  ) {
    throw new Error("Existing payment-confirmation content was not preserved.");
  }
});
