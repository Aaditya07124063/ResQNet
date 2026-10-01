import { prepare, RETENTION_CATEGORIES } from '../src/services/retention/retentionJob';
import { cutoff, isSosSensitiveExpired } from '../src/services/retention/retentionPolicy';
import { isSensitiveAuditKey, redactAuditMetadata } from '../src/utils/auditRedaction';
import { sosSensitiveRemoved, toSosEvent, type DbSosEventRow } from '../src/models/SosEvent';

const DAY = 86_400_000;
const now = new Date('2026-09-28T12:00:00.000Z');

describe('named parameters', () => {
  it('sends only the parameters a statement uses, typed, and leaves ::casts alone', () => {
    const q = prepare('SELECT x::text FROM t WHERE a <= :cutoff AND b = ANY(:keys) AND c <= :cutoff', {
      cutoff: { value: now, cast: 'timestamptz' },
      now: { value: now, cast: 'timestamptz' },
      keys: { value: ['k'], cast: 'uuid[]' },
    });
    expect(q.text).toBe('SELECT x::text FROM t WHERE a <= $1::timestamptz AND b = ANY($2::uuid[]) AND c <= $3::timestamptz');
    expect(q.values).toEqual([now, ['k'], now]);
  });
});

describe('retention boundaries', () => {
  const policy = { sosSensitiveDays: 90 };
  const closedAt = (msBeforeCutoff: number) => new Date(now.getTime() - 90 * DAY - msBeforeCutoff);

  it('exactly at the cutoff is expired; one millisecond younger is not', () => {
    expect(isSosSensitiveExpired({ ops_closed_at: closedAt(0), retention_hold_at: null }, now, policy)).toBe(true);
    expect(isSosSensitiveExpired({ ops_closed_at: closedAt(-1), retention_hold_at: null }, now, policy)).toBe(false);
    expect(cutoff(now, 90).getTime()).toBe(now.getTime() - 90 * DAY);
  });

  it('an open incident or one on hold never expires', () => {
    expect(isSosSensitiveExpired({ ops_closed_at: null, retention_hold_at: null }, now, policy)).toBe(false);
    expect(isSosSensitiveExpired({ ops_closed_at: closedAt(10 * DAY), retention_hold_at: now }, now, policy)).toBe(false);
  });
});

describe('SOS responses', () => {
  const base = {
    id: 'i',
    event_id: 'e',
    user_id: 'u',
    event_source: 'manual',
    category: 'medical',
    message: 'Allergic to penicillin',
    latitude: '27.717245',
    longitude: '85.323961',
    location_accuracy_m: '12',
    status: 'resolved',
    client_created_at: now,
    server_received_at: now,
    resolved_at: now,
    origin_device_id: null,
    origin_key_id: null,
    origin_signature: null,
    origin_claimed_user_id: null,
    origin_verification_state: 'not_applicable',
    origin_envelope_raw: null,
  } as unknown as DbSosEventRow;

  it('masks message and location once past retention or redacted', () => {
    const expired = toSosEvent({ ...base, ops_closed_at: new Date(Date.now() - 400 * DAY), retention_hold_at: null });
    expect(expired).toMatchObject({ sensitiveRemoved: true, message: null, latitude: null, longitude: null, locationAccuracyM: null });
    const redacted = sosSensitiveRemoved({ ops_closed_at: new Date(), sensitive_redacted_at: new Date(), retention_hold_at: null });
    expect(redacted).toBe(true);
    expect(toSosEvent(base)).toMatchObject({ sensitiveRemoved: false, message: 'Allergic to penicillin', latitude: 27.717245 });
  });
});

describe('audit redaction', () => {
  it.each(['accessToken', 'refresh_token', 'password', 'otp', 'apiKey', 'signature', 'latitude', 'lng', 'message', 'note', 'phoneNumber', 'bloodGroup', 'allergies', 'medications', 'address'])(
    'treats %s as sensitive',
    (key) => expect(isSensitiveAuditKey(key)).toBe(true),
  );

  it.each(['hasNote', 'previousState', 'newState', 'actorRole', 'email', 'providerType', 'reason', 'sensitiveDetailsIncluded'])(
    'keeps %s',
    (key) => expect(isSensitiveAuditKey(key)).toBe(false),
  );

  it('caps long strings so free text cannot sneak in under a harmless key', () => {
    const out = redactAuditMetadata({ detail: 'x'.repeat(1000) }) as { detail: string };
    expect(out.detail.length).toBeLessThanOrEqual(301);
  });
});

describe('retention categories (static safety checks)', () => {
  it('SOS categories only ever touch responder-closed incidents that are not on hold', () => {
    for (const c of RETENTION_CATEGORIES.filter((c) => c.table === 'sos_events')) {
      for (const sql of [c.where, c.action]) {
        expect(sql).toContain("ops_status IN ('resolved', 'stood_down')");
        expect(sql).toContain('retention_hold_at IS NULL');
      }
    }
  });

  it('every action re-checks its batch and returns the keys it changed', () => {
    for (const c of RETENTION_CATEGORIES) {
      expect(c.action).toMatch(new RegExp(`${c.key} = ANY\\(:keys\\)`));
      expect(c.action.trim()).toMatch(new RegExp(`RETURNING ${c.key}$`));
    }
  });

  it('names are unique and redaction runs before de-identification before deletion', () => {
    const names = RETENTION_CATEGORIES.map((c) => c.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names.indexOf('sos_sensitive_redaction')).toBeLessThan(names.indexOf('sos_deidentify'));
    expect(names.indexOf('sos_deidentify')).toBeLessThan(names.indexOf('sos_record_delete'));
  });
});
