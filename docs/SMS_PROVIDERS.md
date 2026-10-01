# SMS Providers

ResQNet sends phone sign-in codes by SMS so civilians, trekkers, and responders can recover access to the emergency network with only a basic mobile signal. This document covers the backend SMS provider system (`backend/src/services/sms/`) and its administration in the responder portal.

## OTP ownership

ResQNet owns the entire OTP lifecycle in `verificationService.ts`:

- a 6-digit code from `crypto.randomInt`
- storage as an HMAC-SHA256 digest bound to channel, number, and purpose (keyed from `JWT_ACCESS_SECRET` via HKDF)
- 5-minute expiry, 5 attempts, and single use, with verification done under a row lock
- a 60-second resend cooldown, serialized with a PostgreSQL advisory lock
- IP-keyed and phone-keyed rate limits

SMS providers only deliver the message text. No provider generates, stores, or verifies codes. This is why MSG91 SendOTP is not used (see below).

## Status

| Provider | Channel | API | OTP model | Configuration | Status |
| --- | --- | --- | --- | --- | --- |
| Sparrow SMS | SMS | Sparrow v2 `POST /v2/sms/` | ResQNet | token; sender ID | IMPLEMENTED · REQUIRES ACCOUNT (Nepal only) |
| Twilio | SMS | Programmable Messaging `Messages.json` | ResQNet | Account SID, auth token; From number or Messaging Service SID | IMPLEMENTED · REQUIRES ACCOUNT |
| Vonage | SMS | Messages API `POST /v1/messages` | ResQNet | API key, API secret; sender | IMPLEMENTED · REQUIRES ACCOUNT |
| Plivo | SMS | `POST /v1/Account/{id}/Message/` | ResQNet | Auth ID, auth token; source | IMPLEMENTED · REQUIRES ACCOUNT |
| Sinch | SMS | SMS REST `xms/v1/{plan}/batches` | ResQNet | API token; service plan ID, sender, region | IMPLEMENTED · REQUIRES ACCOUNT |
| Brevo SMS | SMS | `POST /v3/transactionalSMS/send` | ResQNet | API key; sender | IMPLEMENTED · REQUIRES ACCOUNT |
| Zoho Voice SMS | SMS | `POST /rest/json/v1/sms/send` + OAuth refresh | ResQNet | client ID/secret, refresh token; sender ID, data center | IMPLEMENTED · REQUIRES ACCOUNT |
| AWS End User Messaging SMS | SMS | `SendTextMessage` (SMS/Voice v2, SigV4) | ResQNet | access key pair; region, origination identity, optional India DLT IDs | IMPLEMENTED · REQUIRES ACCOUNT |
| MSG91 | SMS | — | — | — | COMING SOON |
| Generic HTTP gateway | SMS | — | — | — | COMING SOON (SSRF risk) |

"Implemented" means the adapter, validation, error classification, and mocked contract tests (`backend/tests/smsProviderAdapters.test.ts`) exist, and the request format follows each provider's official documentation. No provider has been verified with a live send from ResQNet. None is READY until an admin runs the portal's **Test** action with real credentials.

## Fallback

`smsService.sendSms()` tries each enabled provider once, in ascending `priority` (ties are broken by creation time). The same message, and therefore the same code, goes to each provider in turn. The loop stops at the first provider that accepts the message. Each failure is classified by its adapter (`SmsProviderError`):

| Failure | Meaning | Next provider tried? | Logged as |
| --- | --- | --- | --- |
| `availability` | network, timeout, 408/429/5xx, credit exhaustion | yes | warn |
| `configuration` | rejected credentials, sender, or settings; unreadable stored credentials | yes | error |
| `unsupported` | provider does not serve the destination country (e.g. Sparrow outside +977) | yes | info |
| `recipient` | number itself rejected | no — API returns 400 | error |

Configuration failures still advance the fallback, because another provider has independent credentials, but they are logged at error level and shown in test results. That keeps them visible even when a working fallback hides them from users. The OTP row records the delivering `provider_type`. If a provider times out after already accepting the message, the user can receive the same code twice. That is accepted in preference to no code at all.

## Administration

Routes: `/api/v1/employee/sms-providers`. Every route requires an employee session plus the `SMS_PROVIDER_MANAGE` permission (`super_admin` has it implicitly).

- `GET /` returns the provider catalog and the configured providers. Credentials are never returned, only `configuredCredentialFields`.
- `POST /` creates a provider (disabled by default). Coming-soon providers are rejected.
- `PATCH /:id` updates a provider. A blank secret keeps the stored value; `null` or an empty configuration value clears an optional setting. Disabling, renaming, and re-prioritizing always work, even if the stored settings are invalid.
- `DELETE /:id` soft-disables the provider; the row and its test history are kept.
- `POST /:id/test` sends one code-free test SMS through that provider only. It is limited to 5 per 15 minutes per employee, and the result is classified and stored as `last_test_status`.

Every change is audit-logged with field names only, never values. Credentials are encrypted with AES-256-GCM (`PROVIDER_CREDENTIALS_ENCRYPTION_KEY`, 32 bytes base64). There is no plaintext fallback. The portal lives in the app under **Profile → Responder portal**.

## Provider notes

**Sparrow SMS** — [docs](https://docs.sparrowsms.com/sms/outgoing_sendsms/). Nepal only: `to` is a bare 10-digit Nepali mobile number, and non-+977 numbers are reported as `unsupported`. Error codes: 1002/1008 → configuration, 1007/1011 → recipient, 1012/1013 (credits) → availability. No per-message ID is returned. The sender ID must be approved by Sparrow.

**Twilio** — [docs](https://www.twilio.com/docs/messaging/api/message-resource). Uses Basic auth with Account SID and auth token. `MessagingServiceSid` takes precedence over `From`. Errors 21211/21614/21610 → recipient, 21408 (geo permission) → unsupported, 20429 → availability. India delivery requires Twilio-side sender and DLT registration; there is no per-message DLT field.

**Vonage** — [docs](https://developer.vonage.com/en/messages/overview). Uses the Messages API; Vonage labels the older SMS API as legacy. Basic auth with API key and secret, and `to` without the leading `+`.

**Plivo** — [docs](https://www.plivo.com/docs/messaging/api/messages). `dst` is E.164 with `+`. Plivo has deprecated its per-message India DLT fields, so none are sent.

**Sinch** — [docs](https://developers.sinch.com/docs/sms/api-reference/). Uses a Bearer token per service plan. The region is restricted to `us`, `eu`, `au`, `br`, `ca` so the request host cannot be redirected. The batch field names follow Sinch's SDK documentation; confirm them against the reference page before production use.

**Brevo SMS** — [docs](https://developers.brevo.com/reference/send-async-transactional-sms). Uses the `api-key` header and type `transactional`. The sender is up to 11 alphanumeric or 15 numeric characters. `not_enough_credits` → availability. Brevo documents no India DLT fields.

**Zoho Voice SMS** — [docs](https://help.zoho.com/portal/en/kb/zoho-voice/zoho-voice-apis/articles/sms-rest-api). This is Zoho Voice. Zoho Mail and ZeptoMail are email products and are not SMS providers. Zoho access tokens expire hourly, so the adapter stores a self-client refresh token (scope `ZohoVoice.sms.CREATE`) and exchanges it at `accounts.zoho.{dc}`, caching the access token in memory. The data center is one of `com`, `in`, `eu`, `com.au`. Only `.com` was confirmed in Zoho Voice's API page, so verify the regional domain for your account.

**AWS End User Messaging SMS** — [docs](https://docs.aws.amazon.com/pinpoint/latest/apireference_smsvoicev2/API_SendTextMessage.html). AWS recommends this API over SNS Publish for direct transactional SMS. The request is signed with SigV4 without the AWS SDK; the protocol values come from the AWS SDK service model (`pinpoint-sms-voice-v2`: JSON 1.0, signing name `sms-voice`), and the signer is tested against AWS's SigV4 test-suite vectors. Use an IAM user limited to `sms-voice:SendTextMessage`. Instance or role credentials are not supported without the SDK. For `+91` destinations the optional `in_entity_id`/`in_template_id` are sent as `DestinationCountryParameters` (India DLT). Nepal support is not documented by AWS. The account must be moved out of the SMS sandbox.

**MSG91 — coming soon.** MSG91 SendOTP stores and verifies codes on MSG91, which would move the OTP lifecycle out of ResQNet. The template Flow API could deliver a ResQNet-generated code as a template variable, but its reference documentation could not be retrieved in a verifiable form. It stays unavailable until the request contract is confirmed.

**Generic HTTP gateway — coming soon.** An admin-supplied URL would let the backend be pointed at internal services (SSRF). It needs allowlisting, private-network and DNS-rebinding protection, and redirect restrictions before it can be offered. Every implemented adapter uses a fixed `https` host, refuses redirects, and applies a 10-second timeout.

**Researched, not added:** Infobip (`/sms/3/messages`, `App` API-key auth), Telnyx (`/v2/messages`), and Bird (Channels API, replacing MessageBird). They can be added through the same registry when there is an operational need.

## India and Nepal

- **Nepal:** Sparrow SMS has direct domestic routes. The other providers' Nepal coverage and sender rules depend on the account and are not documented in their API references, so verify with a test send.
- **India:** senders and templates must be DLT-registered. Where a provider handles DLT at the account level (Twilio, MSG91, Plivo), there is nothing to configure per message. AWS takes `IN_ENTITY_ID`/`IN_TEMPLATE_ID` per message, and ResQNet sends them only for `+91` numbers. The OTP text (`Your ResQNet verification code is <code>. It expires in 5 minutes.`) must match the registered template.
