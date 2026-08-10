export const PAYMENT_CONFIRMATION_TEMPLATE_NAME =
  "gen_alpha_renewal_confirmation_v2";

export const PAYMENT_CONFIRMATION_TEMPLATE_BODY = `✅ *Payment Confirmed!* 🏏

Hi! We've successfully received the payment for *{{1}}'s* *{{2}}*. The training status has been updated until *{{3}}*.

*Amount received: Rs {{4}}.*

Great to see the commitment! We are excited to continue working with your child and watching progress every day. Let's keep the game going! 🏏

Thank you for being part of Gen Alpha Cricket Academy!`;

export type RenewalConfirmationValues = {
  playerName: string;
  actionText: string;
  paidThroughText: string;
  amountText: string;
};

export function renewalConfirmationTemplateValues(
  values: RenewalConfirmationValues,
): string[] {
  return [
    values.playerName || "Player",
    values.actionText || "renewal",
    values.paidThroughText,
    values.amountText,
  ];
}

export function buildRenewalConfirmationMessage(
  values: RenewalConfirmationValues,
): string {
  return renewalConfirmationTemplateValues(values).reduce(
    (message, value, index) => message.replaceAll(`{{${index + 1}}}`, value),
    PAYMENT_CONFIRMATION_TEMPLATE_BODY,
  );
}
