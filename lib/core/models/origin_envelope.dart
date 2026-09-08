import '../utils/origin_signable_fields.dart';

/// A cryptographically signed claim of SOS origin — the Dart-side mirror
/// of backend/src/validation/originEnvelopeSchema.ts's `OriginEnvelopeInput`
/// (Phase 1). Field names match exactly so this serializes directly into
/// the `originEnvelope` body field `POST /api/v1/sos` already accepts.
///
/// Carries the origin's own SPKI PEM public key (`originPublicKeyPem`) —
/// NOT secret, and necessary so a receiving device with no connectivity
/// can still run a real local signature check (core/utils/
/// origin_signature_verifier.dart, using the pointycastle package's
/// audited ECDSA implementation — never a hand-rolled one, and never
/// used for SIGNING, only verification). This LOCAL check proves the
/// canonical payload has not been altered since it was signed and that
/// whoever produced it holds the private key matching the embedded
/// public key — it does NOT prove that key is registered to any real
/// ResQNet account, because a relay (or an attacker) could embed a
/// freshly-generated keypair of their own and self-sign consistently.
/// Only the backend, checking `keyId`/signature against its own
/// registered `device_keys.public_key` row (Phase 1's
/// `verifyOriginSignature`), can make that stronger claim. These two
/// checks are kept explicitly distinct everywhere — see the trust-tier
/// documentation in core/services/emergency_communication_service.dart.
class OriginEnvelope {
  final String protocolVersion;
  final String originDeviceId;
  final String eventType;
  final String eventSource;
  final String category;
  final String? message;
  final String? latitude;
  final String? longitude;
  final String? locationAccuracyM;
  final String createdAt;
  final String expiresAt;
  final int maxHops;
  final String priority;
  final String? originClaimedUserId;
  final String keyId;
  final String signature;

  /// The origin's own public key, SPKI PEM — see class doc comment.
  /// Nullable only so envelopes persisted before this field existed still
  /// deserialize; a null value here means this envelope can never be
  /// locally signature-checked (falls back to signaturePresentUnverified),
  /// never that it should be treated as verified.
  final String? originPublicKeyPem;

  const OriginEnvelope({
    required this.protocolVersion,
    required this.originDeviceId,
    required this.eventType,
    required this.eventSource,
    required this.category,
    this.message,
    this.latitude,
    this.longitude,
    this.locationAccuracyM,
    required this.createdAt,
    required this.expiresAt,
    required this.maxHops,
    required this.priority,
    this.originClaimedUserId,
    required this.keyId,
    required this.signature,
    this.originPublicKeyPem,
  });

  /// The exact fields that were signed (excludes keyId/signature/
  /// originClaimedUserId themselves, plus the eventId which lives
  /// alongside this envelope, not inside it — matches
  /// backend/src/validation/originEnvelopeSchema.ts's toSignableOriginFields).
  SignableOriginFields toSignableFields(String eventId) => SignableOriginFields(
        protocolVersion: protocolVersion,
        eventId: eventId,
        originDeviceId: originDeviceId,
        eventType: eventType,
        eventSource: eventSource,
        category: category,
        message: message ?? '',
        latitude: latitude ?? '',
        longitude: longitude ?? '',
        locationAccuracyM: locationAccuracyM ?? '',
        createdAt: createdAt,
        expiresAt: expiresAt,
        maxHops: maxHops.toString(),
        priority: priority,
      );

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'originDeviceId': originDeviceId,
        'eventType': eventType,
        'eventSource': eventSource,
        'category': category,
        'message': message,
        'latitude': latitude,
        'longitude': longitude,
        'locationAccuracyM': locationAccuracyM,
        'createdAt': createdAt,
        'expiresAt': expiresAt,
        'maxHops': maxHops,
        'priority': priority,
        'originClaimedUserId': originClaimedUserId,
        'keyId': keyId,
        'signature': signature,
        'originPublicKeyPem': originPublicKeyPem,
      };

  factory OriginEnvelope.fromJson(Map<String, dynamic> json) => OriginEnvelope(
        protocolVersion: json['protocolVersion'] as String,
        originDeviceId: json['originDeviceId'] as String,
        eventType: json['eventType'] as String,
        eventSource: json['eventSource'] as String,
        category: json['category'] as String,
        message: json['message'] as String?,
        latitude: json['latitude'] as String?,
        longitude: json['longitude'] as String?,
        locationAccuracyM: json['locationAccuracyM'] as String?,
        createdAt: json['createdAt'] as String,
        expiresAt: json['expiresAt'] as String,
        maxHops: json['maxHops'] as int,
        priority: json['priority'] as String,
        originClaimedUserId: json['originClaimedUserId'] as String?,
        keyId: json['keyId'] as String,
        signature: json['signature'] as String,
        originPublicKeyPem: json['originPublicKeyPem'] as String?,
      );
}
