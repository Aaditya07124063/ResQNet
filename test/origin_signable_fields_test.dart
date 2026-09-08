import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/utils/origin_signable_fields.dart';

SignableOriginFields _base({
  String message = 'need help',
  String latitude = '12.345600',
  String longitude = '77.654300',
  String locationAccuracyM = '15.50',
  String category = 'medical',
}) =>
    SignableOriginFields(
      protocolVersion: '1',
      eventId: '11111111-1111-1111-1111-111111111111',
      originDeviceId: '22222222-2222-2222-2222-222222222222',
      eventType: 'sos',
      eventSource: 'manual',
      category: category,
      message: message,
      latitude: latitude,
      longitude: longitude,
      locationAccuracyM: locationAccuracyM,
      createdAt: '2026-01-01T00:00:00.000Z',
      expiresAt: '2026-01-01T00:10:00.000Z',
      maxHops: '5',
      priority: 'critical',
    );

void main() {
  group('buildSignableString', () {
    test('is deterministic for the same fields', () {
      expect(buildSignableString(_base()), buildSignableString(_base()));
    });

    test('changes when a single field changes', () {
      final base = buildSignableString(_base());
      final changed = buildSignableString(_base(category: 'fire'));
      expect(changed, isNot(equals(base)));
    });

    test('is resistant to field-boundary shifting via length-prefixed framing', () {
      final a = buildSignableString(_base(category: 'a', message: 'b|c'));
      final b = buildSignableString(_base(category: 'a|b', message: 'c'));
      expect(a, isNot(equals(b)));
    });

    test('matches the exact byte-length-prefixed shape the backend expects for a known input', () {
      // A hand-computed expectation for a minimal, all-ASCII input — this
      // is the cross-language contract check: if this ever fails, the
      // Dart and TypeScript implementations have silently drifted apart,
      // which would make every signature produced by this app fail
      // backend verification.
      const fields = SignableOriginFields(
        protocolVersion: '1',
        eventId: 'e',
        originDeviceId: 'd',
        eventType: 'sos',
        eventSource: 'manual',
        category: 'c',
        message: '',
        latitude: '',
        longitude: '',
        locationAccuracyM: '',
        createdAt: 't1',
        expiresAt: 't2',
        maxHops: '5',
        priority: 'critical',
      );
      const expected =
          '18:resqnet-sos-sig-v1' // domain, length 18
          '1:1' // protocolVersion
          '1:e' // eventId
          '1:d' // originDeviceId
          '3:sos' // eventType
          '6:manual' // eventSource
          '1:c' // category
          '0:' // message (empty)
          '0:' // latitude (empty)
          '0:' // longitude (empty)
          '0:' // locationAccuracyM (empty)
          '2:t1' // createdAt
          '2:t2' // expiresAt
          '1:5' // maxHops
          '8:critical'; // priority
      expect(buildSignableString(fields), expected);
    });

    test('length prefix counts UTF-8 bytes, not UTF-16 code units, for non-ASCII text', () {
      // 'é' is 1 UTF-16 code unit but 2 UTF-8 bytes — a length-prefix bug
      // using .length (code units) instead of UTF-8 byte length would
      // silently produce a different frame than the backend's
      // Buffer.byteLength('utf8')-based implementation.
      final withAccent = buildSignableString(_base(message: 'é'));
      expect(withAccent, contains('2:é'));
    });
  });
}
