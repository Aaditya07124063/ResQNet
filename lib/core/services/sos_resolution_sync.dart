import 'package:flutter/foundation.dart';
import '../models/emergency_outbox_entry.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import 'emergency_outbox_store.dart';

/// Pushes a user's SOS cancellation ("I'm safe" / false alarm) to the
/// backend (`PATCH /api/v1/sos/{eventId}`), recording the outcome on the
/// outbox entry. Shared by [SosService] (immediate attempt) and
/// [EmergencyCommunicationService] (retry once connectivity returns), so
/// both follow exactly the same rules:
///
/// - only an SOS the backend has accepted can be updated remotely;
/// - network, 5xx, and authentication failures stay `pending` and are
///   retried — never reported as done;
/// - a 404 means the backend has no such event for this user, so there
///   is nothing to update (`notNeeded`).
Future<ResolutionSyncState> pushSosResolution(
  String eventId, {
  EmergencyOutboxStore? store,
  ApiClient? client,
}) async {
  final outbox = store ?? EmergencyOutboxStore.instance;
  final entry = await outbox.get(eventId);
  if (entry == null || entry.resolution == null) return ResolutionSyncState.none;
  if (entry.resolutionSync == ResolutionSyncState.synced || entry.resolutionSync == ResolutionSyncState.notNeeded) {
    return entry.resolutionSync;
  }
  if (entry.state != OutboxEntryState.serverAccepted && entry.state != OutboxEntryState.deliveryConfirmed) {
    // Not on the backend yet; the sync loop uploads it first.
    return ResolutionSyncState.pending;
  }

  ResolutionSyncState outcome;
  try {
    await (client ?? ApiClient.instance).patch('/sos/$eventId', body: {'status': entry.resolution!.apiValue});
    outcome = ResolutionSyncState.synced;
  } on ApiException catch (e) {
    outcome = e.statusCode == 404 ? ResolutionSyncState.notNeeded : ResolutionSyncState.pending;
    debugPrint('SOS resolution sync ${outcome.name}: ${e.code}');
  } catch (e) {
    outcome = ResolutionSyncState.pending;
    debugPrint('SOS resolution sync pending: $e');
  }
  await outbox.update(eventId, (current) => current.copyWith(resolutionSync: outcome));
  return outcome;
}
