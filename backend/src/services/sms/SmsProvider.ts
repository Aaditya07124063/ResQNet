/**
 * Common interface every SMS adapter (SparrowSmsProvider, and any future
 * one) implements. smsService.ts is the only caller — nothing else in the
 * backend talks to an SMS provider directly, matching "backend must be the
 * only component communicating with the SMS provider" (Flutter never sees
 * provider credentials or this interface at all).
 */
export interface SmsProvider {
  /** Sends `message` to `to` (E.164, e.g. "+9779812345678"). Resolves with
   * an optional provider-assigned message id on success; throws on any
   * failure — never returns a "false but no error" ambiguous result. Must
   * never throw or log anything containing the provider's own credentials. */
  send(to: string, message: string): Promise<{ providerMessageId?: string }>;
}
