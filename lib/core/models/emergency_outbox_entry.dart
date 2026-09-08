import 'origin_envelope.dart';

/// Lifecycle of a locally-created emergency event as it moves toward
/// being genuinely delivered. Distinct, explicit states — never collapsed
/// into a single "sent"/"delivered" boolean, because that is exactly the
/// kind of false confidence this architecture must not create (an event
/// sitting in [queued] is not "delivered" merely because it was queued).
enum OutboxEntryState {
  /// Created locally; no transport attempted yet.
  created,

  /// Waiting for a transport (online or mesh) to become available.
  queued,

  /// Actively searching for nearby ResQNet devices to hand this to.
  discovering,

  /// Handed to at least one nearby peer over mesh transport — this is
  /// TRANSPORT delivery to a stranger's phone, nothing more. Never
  /// displayed to the user as "delivered".
  sentToPeer,

  /// A peer has forwarded this on our behalf (learned via a mesh ACK, if
  /// the transport supports one — see MeshProtocol).
  relayed,

  /// Uploaded to the backend; awaiting its response.
  serverPending,

  /// The backend has recorded this event (POST /api/v1/sos succeeded) —
  /// this is BACKEND AUTHENTICATED, still not the same as origin-verified
  /// or delivery-confirmed; see the trust-tier documentation in
  /// EmergencyCommunicationService.
  serverAccepted,

  /// The event's outcome has been confirmed by an authoritative party
  /// beyond "the backend has a row for it" — reserved for a future,
  /// genuinely-implemented confirmation signal (e.g. a responder
  /// acknowledgement). Not set by anything in this codebase today; exists
  /// so the state model doesn't need to change shape once that exists.
  deliveryConfirmed,

  /// Every attempt exhausted, or the backend permanently rejected it
  /// (e.g. a revoked key, an invalid signature) — terminal.
  failed,

  /// Passed its own TTL (`expiresAt`) before ever reaching the backend —
  /// terminal; must not continue being relayed or retried.
  expired,
}

/// A durable record of one emergency event as it moves through local
/// creation, mesh relay, and eventual backend synchronization. Persisted
/// via [EmergencyOutboxStore] (SharedPreferences-backed, mirroring
/// CommunicationService's existing pending-outbox pattern) so an SOS
/// created offline survives app restart, backgrounding, or a temporary
/// Bluetooth/network outage — it must never exist only in RAM.
class EmergencyOutboxEntry {
  /// The emergency event's own stable identity — same value sent to the
  /// backend as `eventId`, same value used as `EmergencyMessage.id` over
  /// mesh. Never changes for the lifetime of this entry.
  final String eventId;

  final String eventSource;
  final String category;
  final String? message;
  final double? latitude;
  final double? longitude;
  final double? locationAccuracyM;
  final DateTime createdAt;
  final DateTime? expiresAt;

  /// The signed origin claim (Phase 1/4) — null only if this device could
  /// not sign at creation time (see OriginEnvelopeService.build's own
  /// doc comment). An entry with no envelope can still be uploaded
  /// directly while online (the existing JWT-authenticated path doesn't
  /// need one) but cannot be honestly relayed over mesh with any
  /// cryptographic origin claim at all.
  final OriginEnvelope? originEnvelope;

  final OutboxEntryState state;

  /// How many transport attempts (of any kind) have been made — used for
  /// backoff, never for an unbounded retry loop (Section 20: never retry
  /// infinitely). See EmergencyCommunicationService.maxSyncAttempts.
  final int attempts;
  final DateTime? lastAttemptAt;

  /// Never contains a secret (token, key material) — see
  /// EmergencyOutboxStore's own doc comment on what is safe to persist.
  final String? lastError;

  /// Peer device ids (mesh-level, ephemeral endpoint ids) this entry has
  /// already been handed to in the current discovery session — prevents
  /// re-sending to the same already-reached peer repeatedly while still
  /// discovering others.
  final List<String> sentToPeerIds;

  /// Set once the backend has actually accepted this event — the
  /// authoritative origin-verification outcome the backend computed
  /// (Phase 1's `origin_verification_state`), never guessed locally.
  final String? serverOriginVerificationState;

  const EmergencyOutboxEntry({
    required this.eventId,
    required this.eventSource,
    required this.category,
    this.message,
    this.latitude,
    this.longitude,
    this.locationAccuracyM,
    required this.createdAt,
    this.expiresAt,
    this.originEnvelope,
    this.state = OutboxEntryState.created,
    this.attempts = 0,
    this.lastAttemptAt,
    this.lastError,
    this.sentToPeerIds = const [],
    this.serverOriginVerificationState,
  });

  bool get isTerminal => state == OutboxEntryState.failed || state == OutboxEntryState.expired || state == OutboxEntryState.serverAccepted || state == OutboxEntryState.deliveryConfirmed;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  EmergencyOutboxEntry copyWith({
    OutboxEntryState? state,
    int? attempts,
    DateTime? lastAttemptAt,
    String? lastError,
    List<String>? sentToPeerIds,
    String? serverOriginVerificationState,
  }) =>
      EmergencyOutboxEntry(
        eventId: eventId,
        eventSource: eventSource,
        category: category,
        message: message,
        latitude: latitude,
        longitude: longitude,
        locationAccuracyM: locationAccuracyM,
        createdAt: createdAt,
        expiresAt: expiresAt,
        originEnvelope: originEnvelope,
        state: state ?? this.state,
        attempts: attempts ?? this.attempts,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
        lastError: lastError ?? this.lastError,
        sentToPeerIds: sentToPeerIds ?? this.sentToPeerIds,
        serverOriginVerificationState: serverOriginVerificationState ?? this.serverOriginVerificationState,
      );

  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'eventSource': eventSource,
        'category': category,
        'message': message,
        'latitude': latitude,
        'longitude': longitude,
        'locationAccuracyM': locationAccuracyM,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'originEnvelope': originEnvelope?.toJson(),
        'state': state.name,
        'attempts': attempts,
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
        'lastError': lastError,
        'sentToPeerIds': sentToPeerIds,
        'serverOriginVerificationState': serverOriginVerificationState,
      };

  factory EmergencyOutboxEntry.fromJson(Map<String, dynamic> json) => EmergencyOutboxEntry(
        eventId: json['eventId'] as String,
        eventSource: json['eventSource'] as String,
        category: json['category'] as String,
        message: json['message'] as String?,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        locationAccuracyM: (json['locationAccuracyM'] as num?)?.toDouble(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: json['expiresAt'] != null ? DateTime.parse(json['expiresAt'] as String) : null,
        originEnvelope: json['originEnvelope'] != null
            ? OriginEnvelope.fromJson(json['originEnvelope'] as Map<String, dynamic>)
            : null,
        state: OutboxEntryState.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => OutboxEntryState.created,
        ),
        attempts: json['attempts'] as int? ?? 0,
        lastAttemptAt: json['lastAttemptAt'] != null ? DateTime.parse(json['lastAttemptAt'] as String) : null,
        lastError: json['lastError'] as String?,
        sentToPeerIds: (json['sentToPeerIds'] as List?)?.cast<String>() ?? const [],
        serverOriginVerificationState: json['serverOriginVerificationState'] as String?,
      );
}
