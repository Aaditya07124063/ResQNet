import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/sos_alert.dart';
import '../models/emergency_message.dart';
import '../models/emergency_outbox_entry.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import '../services/ai_service.dart';
import '../services/location_service.dart';
import 'emergency_outbox_store.dart';
import 'origin_envelope_service.dart';
import 'sos_resolution_sync.dart';

/// Result of asking to end the active SOS. [remoteState] says honestly
/// whether the backend already knows — the UI must never claim a remote
/// cancellation that is still pending.
class SosCancelOutcome {
  const SosCancelOutcome({required this.alert, required this.remoteState});

  final SosAlert alert;
  final ResolutionSyncState remoteState;
}

/// Owns the local SOS lifecycle: idle → active → resolved.
///
/// - At most one SOS is active at a time. Triggering again while one is
///   active (a repeated tap, or crash/earthquake detection firing during a
///   manual SOS) returns the existing alert instead of creating a second
///   emergency — see [triggerSos].
/// - The active SOS is persisted, so it is still shown as active (and
///   still offered to nearby devices) after the app is killed or restarted.
/// - Every SOS is persisted to [EmergencyOutboxStore] before any network
///   attempt; backend delivery and retries are tracked there.
class SosService extends ChangeNotifier {
  SosService(this._aiService, this._locationService, {@visibleForTesting bool restoreOnCreate = true}) {
    if (restoreOnCreate) _restoring = restore();
  }

  /// Pending restore of a persisted active SOS; a trigger waits for it so
  /// an SOS pressed right after an app restart re-uses the restored one
  /// instead of orphaning it.
  Future<void>? _restoring;

  final AiService _aiService;
  final LocationService _locationService;
  final _uuid = const Uuid();

  static const _activeSosKey = 'resqnet_active_sos_v1';

  final List<SosAlert> _alerts = [];
  SosAlert? _active;
  String _activeEventSource = 'manual';
  Future<SosAlert>? _triggerInFlight;
  bool _restored = false;

  List<SosAlert> get alerts => List.unmodifiable(_alerts);
  SosAlert? get activeAlert => _active;
  String get activeEventSource => _activeEventSource;
  bool get sosActive => _active != null;
  bool get isRestored => _restored;

  /// Reloads a persisted active SOS (e.g. after an app restart). An SOS the
  /// user already resolved is never resurrected.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_activeSosKey);
      if (raw != null && _active == null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final alert = SosAlert.fromJson(json['alert'] as Map<String, dynamic>);
        final entry = await EmergencyOutboxStore.instance.get(alert.id);
        if (entry != null && entry.isResolved) {
          await prefs.remove(_activeSosKey);
        } else {
          _active = alert;
          _activeEventSource = json['eventSource'] as String? ?? 'manual';
          if (!_alerts.any((a) => a.id == alert.id)) _alerts.insert(0, alert);
        }
      }
    } catch (e) {
      debugPrint('Active SOS restore failed: $e');
    } finally {
      _restored = true;
      notifyListeners();
    }
  }

  Future<void> _persistActive() async {
    final prefs = await SharedPreferences.getInstance();
    final active = _active;
    if (active == null) {
      await prefs.remove(_activeSosKey);
    } else {
      await prefs.setString(
        _activeSosKey,
        jsonEncode({'alert': active.toJson(), 'eventSource': _activeEventSource}),
      );
    }
  }

  /// Creates and persists a new SOS — or, if one is already active or being
  /// created, returns that one. This is the duplicate-protection point for
  /// every trigger (Home button, SOS screen, app shortcut, crash and
  /// earthquake detection).
  ///
  /// `eventSource` must match `sos_events.event_source`'s CHECK constraint
  /// (`'manual' | 'crash_detection' | 'earthquake_detection'`).
  ///
  /// Every SOS also gets a signed [OriginEnvelope] (best effort — never
  /// blocks creation if this device can't currently sign) and a durable
  /// [EmergencyOutboxEntry], persisted BEFORE any network attempt so the
  /// event survives an app kill between here and the backend acknowledging it.
  Future<SosAlert> triggerSos({
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
    String eventSource = 'manual',
    String medicalSummary = '',
  }) async {
    final restoring = _restoring;
    if (restoring != null) await restoring;
    final active = _active;
    if (active != null) {
      debugPrint('SOS already active (${active.id}); not creating a duplicate');
      return active;
    }
    return _triggerInFlight ??= _createSos(
      userId: userId,
      userName: userName,
      category: category,
      message: message,
      eventSource: eventSource,
      medicalSummary: medicalSummary,
    ).whenComplete(() => _triggerInFlight = null);
  }

  Future<SosAlert> _createSos({
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
    required String eventSource,
    String medicalSummary = '',
  }) async {
    Position? position;
    try {
      position = await _locationService.getBestEffortLocation();
    } catch (e) {
      debugPrint('Location fetch failed: $e');
    }

    final id = _uuid.v4();
    final createdAt = DateTime.now();

    // Medical details (only when the user opted in, see
    // ProfileService.automaticSosMedicalSummary) are added to the message
    // and signed together with it. If this device cannot sign, they are
    // left out: medical details never travel outside a signed envelope.
    final withMedical = medicalSummary.isEmpty ? message : '$message$medicalSummary';
    final envelope = await OriginEnvelopeService.build(
      eventId: id,
      eventSource: eventSource,
      category: category.name,
      message: withMedical.isEmpty ? null : withMedical,
      latitude: position?.latitude,
      longitude: position?.longitude,
      locationAccuracyM: position?.accuracy,
      createdAt: createdAt,
    );
    final sentMessage = envelope != null ? withMedical : message;

    final alert = SosAlert(
      id: id,
      userId: userId,
      userName: userName,
      category: category,
      message: sentMessage,
      latitude: position?.latitude,
      longitude: position?.longitude,
      locationAccuracyM: position?.accuracy,
      timestamp: createdAt,
      status: SosStatus.active,
    );

    await EmergencyOutboxStore.instance.upsert(EmergencyOutboxEntry(
      eventId: id,
      eventSource: eventSource,
      category: category.name,
      message: sentMessage.isEmpty ? null : sentMessage,
      latitude: position?.latitude,
      longitude: position?.longitude,
      locationAccuracyM: position?.accuracy,
      createdAt: createdAt,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
      originEnvelope: envelope,
      state: OutboxEntryState.queued,
    ));

    _alerts.insert(0, alert);
    _active = alert;
    _activeEventSource = eventSource;
    notifyListeners();
    await _persistActive();

    // Best-effort, non-blocking: this must never stop the mesh broadcast
    // (SosDispatchService, called right after this returns) from reaching
    // nearby offline devices. A failure leaves the outbox entry `queued`
    // for EmergencyCommunicationService to retry.
    unawaited(_reportToBackend(id, eventSource, alert));

    return alert;
  }

  Future<void> _reportToBackend(String eventId, String eventSource, SosAlert alert) async {
    // Recorded as an attempt before sending: if the request reaches the
    // server but the response is lost, a later cancellation must know the
    // backend may already have this SOS.
    final attempting = await EmergencyOutboxStore.instance.update(
      eventId,
      (e) => e.copyWith(
        state: e.isResolved ? null : OutboxEntryState.serverPending,
        attempts: e.attempts + 1,
        lastAttemptAt: DateTime.now(),
      ),
    );
    if (attempting == null || attempting.state == OutboxEntryState.cancelledBeforeUpload) return;

    try {
      final result = await ApiClient.instance.post(
        '/sos',
        auth: true,
        body: {
          'eventId': eventId,
          'eventSource': eventSource,
          'category': alert.category.name,
          'message': alert.message,
          'latitude': alert.latitude,
          'longitude': alert.longitude,
          'clientCreatedAt': alert.timestamp.toIso8601String(),
        },
      );
      final eventData = result['event'] as Map<String, dynamic>?;
      final accepted = await EmergencyOutboxStore.instance.update(
        eventId,
        (e) => e.copyWith(
          state: OutboxEntryState.serverAccepted,
          mayHaveReachedServer: true,
          // If the user cancelled while this was in flight, the backend now
          // has the SOS and must be told it is resolved.
          resolutionSync: e.resolutionSync == ResolutionSyncState.notNeeded ? ResolutionSyncState.pending : null,
          serverOriginVerificationState: eventData?['originVerificationState'] as String?,
        ),
      );
      // The user may have cancelled while this request was in flight.
      if (accepted != null && accepted.resolution != null) {
        await pushSosResolution(eventId);
      }
    } catch (e) {
      debugPrint('Backend SOS event error: $e');
      // A network failure or transient 5xx leaves the entry retryable; only
      // a genuine 4xx rejection of this request's content is terminal.
      final terminal = e is ApiException && !e.isNetworkError && !e.isServerError;
      final neverReached = e is ApiException && e.neverReachedServer;
      await EmergencyOutboxStore.instance.update(
        eventId,
        (existing) => existing.copyWith(
          // A cancellation made while this request was in flight decides
          // the state itself; see cancelActiveSos.
          state: existing.state == OutboxEntryState.cancelledBeforeUpload
              ? null
              : terminal
                  ? OutboxEntryState.failed
                  : OutboxEntryState.queued,
          lastError: e is ApiException ? '${e.code}: ${e.message}' : 'Network unavailable',
          mayHaveReachedServer: neverReached ? null : true,
        ),
      );
    }
  }

  /// Ends the active SOS. Local state changes immediately; the backend is
  /// told when possible (now, or later by EmergencyCommunicationService).
  /// An SOS the backend has never received is not uploaded at all, so
  /// trusted contacts are never alerted about an emergency that was
  /// already withdrawn. Returns null when no SOS is active.
  Future<SosCancelOutcome?> cancelActiveSos(SosResolution resolution) async {
    final alert = _active;
    if (alert == null) return null;

    alert.status = SosStatus.resolved;
    _active = null;
    notifyListeners();
    await _persistActive();

    final now = DateTime.now();
    final updated = await EmergencyOutboxStore.instance.update(alert.id, (e) {
      // Only an SOS the backend has certainly never seen is withheld from
      // upload. An in-flight or possibly-delivered one is resolved remotely
      // instead (uploading it again is idempotent on the backend).
      final neverAttempted =
          !e.mayHaveReachedServer && (e.state == OutboxEntryState.created || e.state == OutboxEntryState.queued);
      return e.copyWith(
        resolution: resolution,
        resolvedAt: now,
        state: neverAttempted ? OutboxEntryState.cancelledBeforeUpload : null,
        resolutionSync: neverAttempted ? ResolutionSyncState.notNeeded : ResolutionSyncState.pending,
      );
    });

    var remoteState = updated?.resolutionSync ?? ResolutionSyncState.notNeeded;
    if (remoteState == ResolutionSyncState.pending) {
      remoteState = await pushSosResolution(alert.id);
    }
    return SosCancelOutcome(alert: alert, remoteState: remoteState);
  }

  /// Kept for existing callers; equivalent to resolving the active SOS
  /// when [alertId] is the active one.
  void cancelSos(String alertId) {
    if (_active?.id == alertId) unawaited(cancelActiveSos(SosResolution.resolved));
  }

  /// Builds the mesh broadcast message for [alert] — including whatever
  /// signed [OriginEnvelope] was produced for it, read back from the
  /// durable outbox so the exact envelope uploaded to the backend is the
  /// one that travels over mesh.
  Future<EmergencyMessage> sosToBroadcastMessage(SosAlert alert, String senderName) async {
    final type = _aiService.classifyEmergency(alert.message);
    final priority = _aiService.assessPriority(alert.message, type);
    final outboxEntry = await EmergencyOutboxStore.instance.get(alert.id);
    final envelope = outboxEntry?.originEnvelope;

    return EmergencyMessage(
      id: alert.id,
      senderId: alert.userId,
      senderName: senderName,
      message: alert.message,
      type: type,
      // An SOS is never relayed below high priority, whatever the text says.
      priority: priority == PriorityLevel.critical ? PriorityLevel.critical : PriorityLevel.high,
      latitude: alert.latitude,
      longitude: alert.longitude,
      timestamp: alert.timestamp,
      originEnvelope: envelope,
      maxHops: envelope?.maxHops ?? EmergencyMessage.defaultMaxHops,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
    );
  }

  /// Builds the mesh notice withdrawing [alert]. Signed with this device's
  /// key when possible — the signed message text binds it to the original
  /// event id, so receivers can check the same device that raised the SOS
  /// is the one cancelling it.
  Future<EmergencyMessage> cancellationBroadcastMessage(
    SosAlert alert,
    String senderName,
    SosResolution resolution,
  ) async {
    final id = _uuid.v4();
    final createdAt = DateTime.now();
    final text = cancellationSignedText(alert.id);
    final envelope = await OriginEnvelopeService.build(
      eventId: id,
      eventSource: 'manual',
      category: alert.category.name,
      message: text,
      createdAt: createdAt,
      priority: 'high',
    );
    return EmergencyMessage(
      id: id,
      senderId: alert.userId,
      senderName: senderName,
      message: resolution == SosResolution.falseAlarm
          ? '$senderName cancelled their SOS (false alarm).'
          : '$senderName is safe — SOS cancelled.',
      type: EmergencyType.general,
      priority: PriorityLevel.high,
      timestamp: createdAt,
      originEnvelope: envelope,
      maxHops: envelope?.maxHops ?? EmergencyMessage.defaultMaxHops,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
      cancelsEventId: alert.id,
    );
  }

  /// This device's own SOS events, newest first, from the durable outbox —
  /// available offline, unlike the backend history.
  Future<List<EmergencyOutboxEntry>> localHistory() async {
    final all = await EmergencyOutboxStore.instance.loadAll();
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
  }
}
