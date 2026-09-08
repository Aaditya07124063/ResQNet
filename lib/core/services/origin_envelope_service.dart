import 'package:uuid/uuid.dart';
import '../models/origin_envelope.dart';
import '../utils/origin_signable_fields.dart';
import 'device_key_service.dart';

/// Builds and signs [OriginEnvelope]s — the one place in the app that
/// composes [DeviceKeyService] (Phase 2/3's platform signing) with the
/// canonical field-framing rules (core/utils/origin_signable_fields.dart,
/// mirroring backend/src/utils/originSignature.ts exactly) into a
/// complete, ready-to-transmit signed envelope.
///
/// Signing failure (no native key module, e.g. mid-Phase-3 on a platform
/// without one yet, or a genuine device capability problem) is NOT
/// escalated as an app-breaking error — [build] returns `null`, and
/// callers fall back to the existing direct/JWT-authenticated path
/// (which needs no envelope at all). An emergency SOS must never be
/// blocked by a cryptography problem.
class OriginEnvelopeService {
  OriginEnvelopeService._();

  static const protocolVersion = '1';

  /// How long a signed SOS envelope remains valid for relay/backend
  /// acceptance after creation. Chosen deliberately generous for the
  /// rural/remote rescue scenarios this app targets — a hiker's SOS
  /// found by a relay hours later should still be actionable — while
  /// still bounding how long a lost/stray envelope can keep circulating
  /// the mesh (Section: TTL/expiry). Documented, not arbitrary: 24 hours
  /// covers a full day-night cycle in the field without being "forever".
  static const defaultTtl = Duration(hours: 24);

  /// Hop budget for mesh relay (Phase 5/7's maxHops). 8 balances "reach
  /// enough nearby devices to plausibly find one with internet" against
  /// "don't let a single event circulate an unbounded number of phones".
  static const defaultMaxHops = 8;

  /// Builds and signs a complete [OriginEnvelope] for a new SOS event.
  /// Returns `null` (never throws) if this device cannot currently sign —
  /// the caller must treat that as "proceed without an envelope", not as
  /// a fatal error.
  static Future<OriginEnvelope?> build({
    required String eventId,
    required String eventSource,
    required String category,
    String? message,
    double? latitude,
    double? longitude,
    double? locationAccuracyM,
    required DateTime createdAt,
    String priority = 'critical',
    int maxHops = defaultMaxHops,
    Duration ttl = defaultTtl,
    String? originClaimedUserId,
  }) async {
    final DeviceKeyRegistrationMaterial material;
    try {
      material = await DeviceKeyService.instance.ensureKeyPair();
    } on DeviceKeyUnavailableException {
      return null;
    }

    final latString = formatDegrees(latitude);
    final lngString = formatDegrees(longitude);
    final accuracyString = formatAccuracy(locationAccuracyM);
    final createdAtIso = createdAt.toUtc().toIso8601String();
    final expiresAtIso = createdAt.toUtc().add(ttl).toIso8601String();

    final signableFields = SignableOriginFields(
      protocolVersion: protocolVersion,
      eventId: eventId,
      originDeviceId: material.deviceId,
      eventType: 'sos',
      eventSource: eventSource,
      category: category,
      message: message ?? '',
      latitude: latString ?? '',
      longitude: lngString ?? '',
      locationAccuracyM: accuracyString ?? '',
      createdAt: createdAtIso,
      expiresAt: expiresAtIso,
      maxHops: maxHops.toString(),
      priority: priority,
    );

    final String signature;
    try {
      signature = await DeviceKeyService.instance.signCanonicalString(buildSignableString(signableFields));
    } on DeviceKeyUnavailableException {
      return null;
    }

    return OriginEnvelope(
      protocolVersion: protocolVersion,
      originDeviceId: material.deviceId,
      eventType: 'sos',
      eventSource: eventSource,
      category: category,
      message: message,
      latitude: latString,
      longitude: lngString,
      locationAccuracyM: accuracyString,
      createdAt: createdAtIso,
      expiresAt: expiresAtIso,
      maxHops: maxHops,
      priority: priority,
      originClaimedUserId: originClaimedUserId,
      keyId: material.keyId,
      signature: signature,
      originPublicKeyPem: material.publicKeyPem,
    );
  }

  /// Fixed 6-decimal-place formatting — matches backend's
  /// `decimalDegreesPattern` (`^-?\d{1,3}\.\d{6}$`) exactly. Returns null
  /// for a null input rather than "0.000000", so "no location" is never
  /// confused with "at the equator/prime meridian" (never fabricate a
  /// coordinate).
  static String? formatDegrees(double? value) {
    if (value == null) return null;
    return value.toStringAsFixed(6);
  }

  /// Fixed 2-decimal-place formatting — matches backend's
  /// `accuracyPattern` (`^\d{1,6}\.\d{2}$`). Accuracy is always
  /// non-negative; a defensively-clamped absolute value is used rather
  /// than silently accepting a nonsensical negative reading.
  static String? formatAccuracy(double? value) {
    if (value == null) return null;
    return value.abs().toStringAsFixed(2);
  }

  /// A collision-resistant random identifier for a single mesh
  /// transmission (Phase 5's `messageId`) — uses the same `uuid` package
  /// (v4) already used throughout this codebase (SosService,
  /// MeshService), not a new ID scheme.
  static String randomId() => const Uuid().v4();
}
