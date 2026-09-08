import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/services/hazard_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Hazard construction defaults', () {
    test('a minimally-constructed hazard gets sensible, non-null defaults for every new field', () {
      final h = Hazard(
        id: 'h1',
        type: 'flood',
        description: 'water rising',
        latitude: 1.0,
        longitude: 2.0,
        reporter: 'Someone',
      );
      expect(h.source, HazardSource.peerReported);
      expect(h.severity, HazardSeverity.moderate);
      expect(h.status, HazardStatus.active);
      expect(h.confidence, 1.0);
      expect(h.radiusM, isNull);
      expect(h.observedAt, isNotNull);
      expect(h.publishedAt, isNotNull);
      expect(h.expiresAt.isAfter(DateTime.now()), true);
    });

    test('timestamp getter mirrors publishedAt for backward compatibility with existing call sites', () {
      final published = DateTime(2026, 1, 1, 12);
      final h = Hazard(
        id: 'h2',
        type: 'fire',
        description: 'smoke visible',
        latitude: 0,
        longitude: 0,
        publishedAt: published,
        reporter: 'r',
      );
      expect(h.timestamp, published);
    });
  });

  group('freshness and expiry', () {
    test('a hazard just created is not expired', () {
      final h = Hazard(id: 'h3', type: 'fire', description: '', latitude: 0, longitude: 0, reporter: 'r');
      expect(h.isExpired, false);
    });

    test('a hazard past its explicit expiresAt is expired, even if status says active', () {
      final h = Hazard(
        id: 'h4',
        type: 'fire',
        description: '',
        latitude: 0,
        longitude: 0,
        publishedAt: DateTime.now().subtract(const Duration(hours: 30)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 6)),
        status: HazardStatus.active,
        reporter: 'r',
      );
      expect(h.isExpired, true);
    });

    test('a retracted hazard is expired regardless of its expiresAt timestamp', () {
      final h = Hazard(
        id: 'h5',
        type: 'fire',
        description: '',
        latitude: 0,
        longitude: 0,
        expiresAt: DateTime.now().add(const Duration(days: 1)), // far in the future
        status: HazardStatus.retracted,
        reporter: 'r',
      );
      expect(h.isExpired, true);
    });

    test('freshnessLabel never claims something is live when it is actually old', () {
      final h = Hazard(
        id: 'h6',
        type: 'fire',
        description: '',
        latitude: 0,
        longitude: 0,
        publishedAt: DateTime.now().subtract(const Duration(hours: 2)),
        reporter: 'r',
      );
      expect(h.freshnessLabel, '2 hr ago');
    });

    test('freshnessLabel reports days for anything a day or older', () {
      final h = Hazard(
        id: 'h7',
        type: 'fire',
        description: '',
        latitude: 0,
        longitude: 0,
        publishedAt: DateTime.now().subtract(const Duration(days: 3)),
        reporter: 'r',
      );
      expect(h.freshnessLabel, '3 days ago');
    });
  });

  group('serialization round-trip', () {
    test('toJson/fromJson preserves every new field exactly', () {
      final original = Hazard(
        id: 'h8',
        source: HazardSource.officialFeed,
        type: 'landslide',
        severity: HazardSeverity.severe,
        description: 'major slide',
        latitude: 27.7,
        longitude: 85.3,
        radiusM: 500.0,
        confidence: 0.85,
        status: HazardStatus.unconfirmed,
        reporter: 'DHM Nepal',
      );
      final roundTripped = Hazard.fromJson(original.toJson())!;

      expect(roundTripped.source, HazardSource.officialFeed);
      expect(roundTripped.severity, HazardSeverity.severe);
      expect(roundTripped.radiusM, 500.0);
      expect(roundTripped.confidence, 0.85);
      expect(roundTripped.status, HazardStatus.unconfirmed);
      expect(roundTripped.observedAt.toIso8601String(), original.observedAt.toIso8601String());
      expect(roundTripped.expiresAt.toIso8601String(), original.expiresAt.toIso8601String());
    });
  });

  group('input validation — malformed/adversarial mesh input never crashes', () {
    test('an unknown severity string falls back to moderate rather than throwing', () {
      final json = {
        'id': 'bad-1',
        'type': 'fire',
        'severity': 'catastrophic_made_up_value',
        'description': '',
        'latitude': 0.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      final h = Hazard.fromJson(json)!;
      expect(h.severity, HazardSeverity.moderate);
    });

    test('an unknown status string falls back to active rather than throwing', () {
      final json = {
        'id': 'bad-2',
        'type': 'fire',
        'status': 'not_a_real_status',
        'description': '',
        'latitude': 0.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      final h = Hazard.fromJson(json)!;
      expect(h.status, HazardStatus.active);
    });

    test('an unknown source string falls back to peerReported rather than throwing', () {
      final json = {
        'id': 'bad-3',
        'type': 'fire',
        'source': 'not_a_real_source',
        'description': '',
        'latitude': 0.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      final h = Hazard.fromJson(json)!;
      expect(h.source, HazardSource.peerReported);
    });

    test('a confidence value outside [0,1] is clamped, never trusted verbatim', () {
      final json = {
        'id': 'bad-4',
        'type': 'fire',
        'confidence': 5.0,
        'description': '',
        'latitude': 0.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      final h = Hazard.fromJson(json)!;
      expect(h.confidence, 1.0);
    });

    test('a missing/malformed timestamp string does not throw — falls back to now', () {
      final json = {
        'id': 'bad-5',
        'type': 'fire',
        'observedAt': 'not-a-date',
        'publishedAt': 'also-not-a-date',
        'description': '',
        'latitude': 0.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      expect(() => Hazard.fromJson(json), returnsNormally);
    });

    test('missing latitude/longitude (malformed geometry) is rejected safely — returns null, never crashes, never fabricates a location', () {
      final json = {'id': 'bad-6', 'type': 'fire', 'description': '', 'reporter': 'r'};
      expect(() => Hazard.fromJson(json), returnsNormally);
      expect(Hazard.fromJson(json), isNull);
    });

    test('a non-numeric latitude (malformed geometry) is rejected safely', () {
      final json = {
        'id': 'bad-7',
        'type': 'fire',
        'description': '',
        'latitude': 'not-a-number',
        'longitude': 0.0,
        'reporter': 'r',
      };
      expect(() => Hazard.fromJson(json), returnsNormally);
      expect(Hazard.fromJson(json), isNull);
    });

    test('an out-of-range coordinate (malformed geometry) is rejected safely, never clamped to a fake nearby point', () {
      final json = {
        'id': 'bad-8',
        'type': 'fire',
        'description': '',
        'latitude': 999.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      expect(Hazard.fromJson(json), isNull);
    });

    test('a missing id is rejected safely — never fabricates one (would break dedup)', () {
      final json = {'type': 'fire', 'description': '', 'latitude': 0.0, 'longitude': 0.0, 'reporter': 'r'};
      expect(() => Hazard.fromJson(json), returnsNormally);
      expect(Hazard.fromJson(json), isNull);
    });

    test('an unknown hazard type string is preserved as-is and handled safely (default icon/color/label)', () {
      final json = {
        'id': 'bad-9',
        'type': 'meteor_strike_not_a_real_type',
        'description': '',
        'latitude': 0.0,
        'longitude': 0.0,
        'reporter': 'r',
      };
      final h = Hazard.fromJson(json)!;
      expect(h.type, 'meteor_strike_not_a_real_type');
      expect(h.typeLabel, 'Hazard'); // safe default label, never throws on an unrecognized type
    });
  });

  group('HazardService — source and freshness retained through the full mesh-sync lifecycle', () {
    test('syncFromMesh absorbs a hazard and preserves its source/severity/status exactly', () async {
      final officialHazard = Hazard(
        id: 'sync-1',
        source: HazardSource.officialFeed,
        type: 'flood',
        severity: HazardSeverity.high,
        description: 'river overflow',
        latitude: 1,
        longitude: 2,
        reporter: 'Official Feed',
      );
      final service = HazardService();
      service.syncFromMesh([
        // Reuse ingestExternal's own encoding so this test exercises the
        // real wire format, not a hand-rolled one.
        service.ingestExternal(officialHazard),
      ]);

      final stored = service.hazards.firstWhere((h) => h.id == 'sync-1');
      expect(stored.source, HazardSource.officialFeed);
      expect(stored.severity, HazardSeverity.high);
    });

    test('an already-expired hazard is never absorbed as active via mesh sync', () async {
      final expiredHazard = Hazard(
        id: 'sync-2',
        type: 'fire',
        description: '',
        latitude: 0,
        longitude: 0,
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        reporter: 'r',
      );
      final service = HazardService();
      final encoded = service.ingestExternal(expiredHazard);
      // ingestExternal itself stores it locally (the reporting device's
      // own record) — the check that matters is the RECEIVING device's
      // syncFromMesh never re-absorbing an already-expired one.
      final receiver = HazardService();
      receiver.syncFromMesh([encoded]);
      expect(receiver.hazards.any((h) => h.id == 'sync-2'), false);
    });

    test('load() skips a malformed persisted record without losing the other, valid ones', () async {
      SharedPreferences.setMockInitialValues({
        'hazards': jsonEncode([
          {'id': 'good-1', 'type': 'flood', 'description': '', 'latitude': 1.0, 'longitude': 2.0, 'reporter': 'r'},
          {'id': 'missing-coords', 'type': 'fire', 'description': '', 'reporter': 'r'}, // malformed — no lat/lng
          {'type': 'fire', 'description': '', 'latitude': 1.0, 'longitude': 1.0, 'reporter': 'r'}, // malformed — no id
          {'id': 'good-2', 'type': 'landslide', 'description': '', 'latitude': 3.0, 'longitude': 4.0, 'reporter': 'r'},
        ]),
      });
      final service = HazardService();
      await service.load();

      expect(service.hazards.map((h) => h.id).toSet(), {'good-1', 'good-2'});
    });

    test('load() never throws even when the persisted blob is not valid JSON at all', () async {
      SharedPreferences.setMockInitialValues({'hazards': 'not valid json{{{'});
      final service = HazardService();
      await expectLater(service.load(), completes);
      expect(service.hazards, isEmpty);
    });
  });
}
