import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import '../models/emergency_message.dart';
import '../models/emergency_outbox_entry.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import 'emergency_outbox_store.dart';

/// Trust tiers an emergency event can be in — kept explicitly distinct
/// everywhere in this app's UI and logic. None of these implies any of
/// the others; collapsing them into one generic "verified"/"delivered"
/// signal is exactly the false confidence this architecture must avoid.
enum EmergencyTrustTier {
  /// Bytes arrived over a real transport (mesh link, or a request that
  /// reached the backend) — says nothing about who actually sent it.
  transportOnly,

  /// A cryptographic signature is attached, but it has not been checked
  /// against a public key by anyone yet (e.g. no key was embedded, or
  /// this event hasn't reached a device that can check it) — distinct
  /// from [originVerifiedLocally] below, which IS a completed check.
  signaturePresentUnverified,

  /// THIS device ran a real local ECDSA check (core/utils/
  /// origin_signature_verifier.dart) and the signature matches the
  /// embedded public key over the canonical payload — proves the payload
  /// is unaltered since signing and whoever signed it holds that key.
  /// Does NOT prove the key belongs to a registered ResQNet account —
  /// only [originVerifiedByBackend] proves that. UI must show this as
  /// "ORIGIN VERIFIED", never as "BACKEND VERIFIED".
  originVerifiedLocally,

  /// The backend independently verified the signature against a
  /// registered device_keys row and could attribute a real account —
  /// strictly stronger than [originVerifiedLocally].
  originVerifiedByBackend,

  /// The backend recorded the event but could not attribute a verified
  /// origin (Phase 1's 'unverified_unregistered') — preserved, never
  /// dropped, never falsely attributed.
  backendAcceptedUnverifiedOrigin,

  /// Reserved for a future, stronger signal beyond "the backend recorded
  /// it" — e.g. an explicit acknowledgment that a responder/rescue
  /// channel actually received it. Not set anywhere in this codebase
  /// today (see [OutboxEntryState.deliveryConfirmed]'s own doc comment)
  /// — included here only so the UI's trust-tier vocabulary has a place
  /// for it once it exists, never claimed prematurely.
  deliveryConfirmed,
}

/// The four trust-tier labels every screen must use, verbatim — never a
/// screen-invented synonym like plain "Verified". Maps the six internal
/// [EmergencyTrustTier] values to exactly these four, since three
/// internal values (transportOnly/signaturePresentUnverified/
/// backendAcceptedUnverifiedOrigin) all correctly collapse to the same
/// user-facing claim: "no one has cryptographically confirmed this yet".
enum TrustTierLabel { unverified, originVerified, backendVerified, deliveryConfirmed }

TrustTierLabel trustTierLabelFor(EmergencyTrustTier tier) {
  switch (tier) {
    case EmergencyTrustTier.deliveryConfirmed:
      return TrustTierLabel.deliveryConfirmed;
    case EmergencyTrustTier.originVerifiedByBackend:
      return TrustTierLabel.backendVerified;
    case EmergencyTrustTier.originVerifiedLocally:
      return TrustTierLabel.originVerified;
    case EmergencyTrustTier.transportOnly:
    case EmergencyTrustTier.signaturePresentUnverified:
    case EmergencyTrustTier.backendAcceptedUnverifiedOrigin:
      return TrustTierLabel.unverified;
  }
}

/// Maps a raw backend `sos_events.origin_verification_state` value
/// (Phase 1 — 'not_applicable' | 'verified' | 'unverified_unregistered')
/// onto [EmergencyTrustTier], for screens (sos_history_screen.dart) that
/// read a SOS record straight from the REST API rather than through
/// [EmergencyOutboxEntry]/[EmergencyMessage]. Returns null for
/// 'not_applicable' — the ordinary, direct JWT-authenticated online path
/// never involved mesh relay or a signature, so there is no origin-trust
/// question to surface at all (never render a badge implying otherwise).
EmergencyTrustTier? trustTierForBackendRecord(String? originVerificationState) {
  switch (originVerificationState) {
    case 'verified':
      return EmergencyTrustTier.originVerifiedByBackend;
    case 'unverified_unregistered':
      return EmergencyTrustTier.backendAcceptedUnverifiedOrigin;
    default:
      return null;
  }
}

/// Maps a persisted outbox entry's state onto the trust tier the UI
/// should actually communicate — the single place this mapping is done,
/// so no screen invents its own (possibly inconsistent) interpretation.
EmergencyTrustTier trustTierFor(EmergencyOutboxEntry entry) {
  if (entry.state == OutboxEntryState.deliveryConfirmed) {
    return EmergencyTrustTier.deliveryConfirmed;
  }
  if (entry.state == OutboxEntryState.serverAccepted) {
    return entry.serverOriginVerificationState == 'verified'
        ? EmergencyTrustTier.originVerifiedByBackend
        : EmergencyTrustTier.backendAcceptedUnverifiedOrigin;
  }
  if (entry.originEnvelope != null) {
    return EmergencyTrustTier.signaturePresentUnverified;
  }
  return EmergencyTrustTier.transportOnly;
}

/// Maps a message this device RECEIVED over mesh (as opposed to one this
/// device created — see [trustTierFor]) onto the trust tier the UI
/// should communicate. `originVerifiedLocally` is set by MeshService
/// right after `verifyOriginEnvelopeLocally` runs on receipt — see that
/// function's doc comment for exactly what it does and does not prove.
EmergencyTrustTier trustTierForReceivedMessage(EmergencyMessage message) {
  if (message.originVerifiedLocally) {
    return EmergencyTrustTier.originVerifiedLocally;
  }
  if (message.originEnvelope != null) {
    return EmergencyTrustTier.signaturePresentUnverified;
  }
  return EmergencyTrustTier.transportOnly;
}

/// Phase 8/9: the one place this app synchronizes locally-created,
/// possibly-offline-signed emergency events with the backend once
/// connectivity is available. Does NOT replace SosService (still owns
/// local SOS creation/state) or MeshService (still owns the mesh
/// transport) — it operates on EmergencyOutboxStore's durable records,
/// which both of those already write to.
///
/// Idempotency is structural, not something this service invents: every
/// upload attempt uses the SAME `eventId` every time (Phase 1's
/// `uq_sos_events_event_id`), so a retried, duplicated, or
/// multiply-relayed upload of the same event can never create more than
/// one canonical backend record — the backend's own idempotent-retry
/// handling (unchanged since Phase 1) is the actual mechanism; this
/// service just calls it correctly and repeatedly until it succeeds or
/// terminally fails.
class EmergencyCommunicationService extends ChangeNotifier {
  /// Hard ceiling on retry attempts per event (Section 20: never retry
  /// infinitely). Past this, the event is marked failed — still
  /// preserved locally (Section: never silently discard), just no longer
  /// auto-retried; nothing in this codebase deletes a failed entry.
  static const int maxSyncAttempts = 8;
  static const Duration _baseBackoff = Duration(seconds: 30);

  Timer? _periodicTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _syncInProgress = false;
  DateTime? _lastSyncAttempt;
  DateTime? _lastSyncSuccess;
  String? _lastSyncFailureReason;
  int _lastReconciledCount = 0;

  bool get isSyncing => _syncInProgress;
  DateTime? get lastSyncAttempt => _lastSyncAttempt;
  DateTime? get lastSyncSuccess => _lastSyncSuccess;
  String? get lastSyncFailureReason => _lastSyncFailureReason;
  int get lastReconciledCount => _lastReconciledCount;

  /// Starts BOTH sync triggers this service uses — neither alone is
  /// treated as the sole source of truth (Phase F's explicit requirement):
  ///
  /// 1. A real OS-level connectivity-change listener
  ///    (`connectivity_plus`) — fires an immediate sync attempt the
  ///    moment a network interface comes up, rather than waiting for the
  ///    next periodic tick. This is a SIGNAL to try sooner, not a
  ///    guarantee of success: "connected" here only means an interface
  ///    reports up (a captive portal or DNS-only outage can still report
  ///    "connected" while every real request fails) — [syncPendingEvents]'s
  ///    own per-attempt network-vs-rejection handling (unchanged) is what
  ///    actually determines the outcome, exactly as before this listener
  ///    existed.
  /// 2. A periodic timer — the safety net for the case connectivity
  ///    returns without ever firing a distinct OS change event (observed
  ///    in practice on some platforms/VPN configurations), and for
  ///    retrying an event that failed for a reason OTHER than "no
  ///    connectivity" (e.g. a transient 5xx) after its own backoff
  ///    window elapses — a failed request always stays eligible for the
  ///    next attempt regardless of which trigger fires it.
  void startPeriodicSync({Duration interval = const Duration(minutes: 5)}) {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(interval, (_) => syncPendingEvents());

    _connectivitySubscription?.cancel();
    try {
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
        (results) {
          final hasAnyInterfaceUp = results.any((r) => r != ConnectivityResult.none);
          if (hasAnyInterfaceUp) {
            unawaited(syncPendingEvents());
          }
        },
        onError: (Object e) => debugPrint('Connectivity listener error (falling back to periodic sync only): $e'),
      );
    } catch (e) {
      // No platform connectivity plugin available at all (unexpected in a
      // real app — the plugin is always registered — but must never
      // prevent the periodic-timer fallback above from still running).
      debugPrint('Could not start connectivity listener (falling back to periodic sync only): $e');
    }
  }

  void stopPeriodicSync() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  @override
  void dispose() {
    stopPeriodicSync();
    super.dispose();
  }

  /// Uploads every pending (non-terminal) outbox entry, in priority
  /// order (critical/high categories first — mirrors MeshService's own
  /// relay-priority ordering, so the same "SOS first" rule applies
  /// end-to-end, not just on the mesh hop). Safe to call repeatedly and
  /// concurrently (guarded by [_syncInProgress]) — e.g. from both a
  /// periodic timer and an explicit "connectivity just returned" trigger
  /// firing at once.
  Future<void> syncPendingEvents() async {
    if (_syncInProgress) return;
    _syncInProgress = true;
    _lastSyncAttempt = DateTime.now();
    notifyListeners();

    var reconciled = 0;
    try {
      final pending = await EmergencyOutboxStore.instance.loadPending();
      pending.sort((a, b) => _priorityRank(a).compareTo(_priorityRank(b)));
      for (final entry in pending) {
        final outcome = await _syncOne(entry);
        if (outcome) reconciled++;
      }
      _lastSyncSuccess = DateTime.now();
      _lastSyncFailureReason = null;
    } finally {
      _lastReconciledCount = reconciled;
      _syncInProgress = false;
      notifyListeners();
    }
  }

  int _priorityRank(EmergencyOutboxEntry entry) {
    // SOS categories are always critical in this app today (see
    // OriginEnvelopeService.build's default) — this ranks by the
    // envelope's own signed priority when present, defaulting to
    // "treat as critical" for entries created before this field existed
    // or without an envelope, matching "never starve emergency traffic"
    // rather than silently deprioritizing legacy/envelope-less entries.
    switch (entry.originEnvelope?.priority) {
      case 'critical':
        return 0;
      case 'high':
        return 1;
      case 'normal':
        return 2;
      default:
        return 0;
    }
  }

  /// Returns true if this call resulted in the entry reaching
  /// [OutboxEntryState.serverAccepted] (i.e. genuinely reconciled this
  /// pass), false otherwise (skipped due to backoff, stayed pending, or
  /// terminally failed).
  Future<bool> _syncOne(EmergencyOutboxEntry entry) async {
    if (entry.isExpired) {
      await EmergencyOutboxStore.instance.upsert(
        entry.copyWith(state: OutboxEntryState.expired, lastError: 'Expired before reaching the backend'),
      );
      return false;
    }
    if (entry.attempts >= maxSyncAttempts) {
      await EmergencyOutboxStore.instance.upsert(
        entry.copyWith(state: OutboxEntryState.failed, lastError: 'Maximum sync attempts reached'),
      );
      return false;
    }

    final last = entry.lastAttemptAt;
    if (last != null) {
      // Capped exponential backoff — 30s, 60s, 120s, ... up to 32x base.
      final backoff = _baseBackoff * (1 << entry.attempts.clamp(0, 6));
      if (DateTime.now().difference(last) < backoff) return false;
    }

    final attempting = entry.copyWith(
      state: OutboxEntryState.serverPending,
      attempts: entry.attempts + 1,
      lastAttemptAt: DateTime.now(),
    );
    await EmergencyOutboxStore.instance.upsert(attempting);

    try {
      final body = <String, dynamic>{'eventId': entry.eventId};
      final envelope = entry.originEnvelope;
      if (envelope != null) {
        body['originEnvelope'] = envelope.toJson();
      } else {
        // No envelope (signing was unavailable at creation time) — falls
        // back to the direct/JWT-authenticated shape POST /api/v1/sos has
        // always accepted (Phase 1, unmodified).
        body['eventSource'] = entry.eventSource;
        body['category'] = entry.category;
        body['message'] = entry.message;
        body['latitude'] = entry.latitude;
        body['longitude'] = entry.longitude;
        body['locationAccuracyM'] = entry.locationAccuracyM;
        body['clientCreatedAt'] = entry.createdAt.toIso8601String();
      }

      final result = await ApiClient.instance.post('/sos', auth: true, body: body);
      final eventData = result['event'] as Map<String, dynamic>?;
      final verificationState = eventData?['originVerificationState'] as String?;

      await EmergencyOutboxStore.instance.upsert(
        attempting.copyWith(
          state: OutboxEntryState.serverAccepted,
          serverOriginVerificationState: verificationState,
          lastError: null,
        ),
      );
      debugPrint('mesh_sync_success: ${entry.eventId} state=$verificationState');
      return true;
    } on ApiException catch (e) {
      if (e.isNetworkError || e.isServerError) {
        // Either no response reached us at all, or one did but the
        // backend itself failed (5xx — a deploy in progress, a
        // transient database outage, an unhandled server exception).
        // Neither says anything about THIS request's content being
        // wrong, so neither is ever a terminal failure — both are
        // retried later exactly the same way.
        await EmergencyOutboxStore.instance.upsert(
          attempting.copyWith(state: OutboxEntryState.queued, lastError: e.message),
        );
        _lastSyncFailureReason = e.message;
        return false;
      }
      // A genuine 4xx backend rejection (malformed body, revoked device
      // key, invalid signature, event_id conflict with a different
      // origin) — terminal. Retrying an input the backend has already
      // definitively rejected would never succeed (same reasoning
      // CommunicationService._attemptSend already applies to a 403).
      await EmergencyOutboxStore.instance.upsert(
        attempting.copyWith(state: OutboxEntryState.failed, lastError: '${e.code}: ${e.message}'),
      );
      debugPrint('mesh_sync_failed: ${entry.eventId} ${e.code}');
      _lastSyncFailureReason = e.message;
      return false;
    } catch (e) {
      await EmergencyOutboxStore.instance.upsert(
        attempting.copyWith(state: OutboxEntryState.queued, lastError: e.toString()),
      );
      _lastSyncFailureReason = e.toString();
      return false;
    }
  }
}
