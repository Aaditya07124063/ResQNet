// Audit metadata must never become a copy of sensitive data. Applied when
// an audit event is written (auditLogService) and again when it is read
// (auditLogQueryService), as defence in depth.
//
// Keys are matched, not values: callers pass ids, states, counts and
// field names — never content. Anything that looks like a credential,
// location, message/note text, phone number or medical detail is replaced.

const SECRET_KEY = /token|secret|password|passwd|otp|credential|api[_-]?key|authorization|cookie|session|signature|private/i;
const CONTENT_KEY = /^(message|note|body|text|content|reason_text)$/i;
const LOCATION_KEY = /^(lat|lng|lon|latitude|longitude|location|coordinates|position|accuracy|location_accuracy_m)$/i;
const PERSONAL_KEY = /phone|medical|allerg|medication|blood|address|dob|birth/i;
const MAX_STRING = 300;

export const REDACTED = '[redacted]';

export function isSensitiveAuditKey(key: string): boolean {
  return SECRET_KEY.test(key) || CONTENT_KEY.test(key) || LOCATION_KEY.test(key) || PERSONAL_KEY.test(key);
}

export function redactAuditMetadata(value: unknown, depth = 0): unknown {
  if (typeof value === 'string') return value.length > MAX_STRING ? `${value.slice(0, MAX_STRING)}…` : value;
  if (depth > 4 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.slice(0, 50).map((v) => redactAuditMetadata(v, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
    out[key] = isSensitiveAuditKey(key) ? REDACTED : redactAuditMetadata(v, depth + 1);
  }
  return out;
}
