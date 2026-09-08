import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
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

class SosService extends ChangeNotifier {
  final AiService _aiService;
  final LocationService _locationService;
  final _uuid = const Uuid();

  final List<SosAlert> _alerts = [];
  bool _sosActive = false;

  SosService(this._aiService, this._locationService);

  List<SosAlert> get alerts => List.unmodifiable(_alerts);
  bool get sosActive => _sosActive;

  /// Phase 20: `eventSource` distinguishes a user-tapped SOS from an
  /// auto-detected one, matching `sos_events.event_source`'s exact CHECK
  /// constraint (`'manual' | 'crash_detection' | 'earthquake_detection'`)
  /// — passed straight through from wherever this alert originated
  /// (crash_countdown_dialog.dart / earthquake_alert_dialog.dart /
  /// sos_screen.dart), never guessed here.
  ///
  /// Phase 4/6: every SOS now also gets a signed [OriginEnvelope] (best
  /// effort — never blocks creation if this device can't currently sign,
  /// see OriginEnvelopeService.build's own doc comment) and a durable
  /// [EmergencyOutboxEntry], persisted BEFORE any network attempt so the
  /// event survives an app kill/crash between here and the backend
  /// actually acknowledging it (Section 6: "Persist before attempting
  /// transport").
  Future<SosAlert> triggerSos({
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
    String eventSource = 'manual',
  }) async {
    Position? position;
    try {
      position = await _locationService.getCurrentLocation();
    } catch (e) {
      debugPrint('Location fetch failed: $e');
    }

    final id = _uuid.v4();
    final createdAt = DateTime.now();

    final alert = SosAlert(
      id: id,
      userId: userId,
      userName: userName,
      category: category,
      message: message,
      latitude: position?.latitude,
      longitude: position?.longitude,
      timestamp: createdAt,
      status: SosStatus.active,
    );

    _alerts.insert(0, alert);
    _sosActive = true;
    notifyListeners();

    // Signed BEFORE the outbox entry is written, so the persisted record
    // already carries whatever envelope this device could produce — an
    // SOS is never delayed waiting on this (best-effort, ~milliseconds
    // once a key exists — see DeviceKeyService's in-session caching).
    final envelope = await OriginEnvelopeService.build(
      eventId: id,
      eventSource: eventSource,
      category: category.name,
      message: message.isEmpty ? null : message,
      latitude: position?.latitude,
      longitude: position?.longitude,
      locationAccuracyM: position?.accuracy,
      createdAt: createdAt,
    );

    await EmergencyOutboxStore.instance.upsert(EmergencyOutboxEntry(
      eventId: id,
      eventSource: eventSource,
      category: category.name,
      message: message.isEmpty ? null : message,
      latitude: position?.latitude,
      longitude: position?.longitude,
      locationAccuracyM: position?.accuracy,
      createdAt: createdAt,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
      originEnvelope: envelope,
      state: OutboxEntryState.queued,
    ));

    // Best-effort, non-blocking: this must never stop the mesh broadcast
    // (SosDispatchService, called right after this returns) from
    // reaching nearby offline devices, which is the one delivery path
    // with zero dependency on any network/backend at all. Outcome is
    // reflected in the outbox entry's state either way — a network
    // failure here is NOT silently swallowed the way it used to be; it
    // leaves the entry `queued` for EmergencyCommunicationService to
    // retry once connectivity returns (Phase 9).
    unawaited(_reportToBackend(id, eventSource, alert));

    return alert;
  }

  Future<void> _reportToBackend(String eventId, String eventSource, SosAlert alert) async {
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
      final existing = await EmergencyOutboxStore.instance.get(eventId);
      if (existing != null) {
        await EmergencyOutboxStore.instance.upsert(existing.copyWith(
          state: OutboxEntryState.serverAccepted,
          serverOriginVerificationState: eventData?['originVerificationState'] as String?,
        ));
      }
    } catch (e) {
      debugPrint('Backend SOS event error: $e');
      // Left in its current outbox state (queued) on a network failure OR
      // a transient backend-side failure (5xx) —
      // EmergencyCommunicationService.syncPendingEvents() will retry it
      // either way. Only a genuine 4xx rejection of THIS request's
      // content (rare on this path, since the payload is fully
      // controlled by this method) is terminal — marking a merely-
      // temporarily-unavailable backend as permanently failed here would
      // mean syncPendingEvents() (which only retries non-terminal
      // entries) never gets a chance to retry a perfectly valid SOS.
      final existing = await EmergencyOutboxStore.instance.get(eventId);
      if (existing != null && e is ApiException && !e.isNetworkError && !e.isServerError) {
        await EmergencyOutboxStore.instance.upsert(existing.copyWith(
          state: OutboxEntryState.failed,
          lastError: '${e.code}: ${e.message}',
        ));
      }
    }
  }

  /// Builds the mesh broadcast message for [alert] — including whatever
  /// signed [OriginEnvelope] was produced for it (Phase 4/5), read back
  /// from the durable outbox rather than re-derived, so the exact same
  /// envelope that was (or will be) uploaded to the backend is what
  /// travels over mesh, never a second, independently-built one.
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
      priority: priority,
      latitude: alert.latitude,
      longitude: alert.longitude,
      timestamp: alert.timestamp,
      originEnvelope: envelope,
      maxHops: envelope?.maxHops ?? EmergencyMessage.defaultMaxHops,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
    );
  }

  void cancelSos(String alertId) {
    final idx = _alerts.indexWhere((a) => a.id == alertId);
    if (idx != -1) {
      _alerts[idx].status = SosStatus.resolved;
      _sosActive = false;
      notifyListeners();
    }
  }
}
