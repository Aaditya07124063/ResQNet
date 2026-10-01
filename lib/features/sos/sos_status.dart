import '../../core/models/emergency_outbox_entry.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/location_service.dart';

/// Severity of one status line, rendered with an icon AND text — never
/// colour alone.
enum SosStatusTone { good, pending, problem }

class SosStatusLine {
  const SosStatusLine({required this.label, required this.value, required this.tone, this.action});

  final String label;
  final String value;
  final SosStatusTone tone;

  /// Something the user can do about it (e.g. "Open settings").
  final SosStatusAction? action;
}

enum SosStatusAction { openLocationSettings }

/// Everything the active-SOS UI shows, derived only from real state: the
/// alert, its outbox entry, mesh handoffs, and connectivity. Wording never
/// upgrades a transport handoff into "delivered".
List<SosStatusLine> describeActiveSos({
  required SosAlert alert,
  required EmergencyOutboxEntry? entry,
  required int meshPeersReached,
  required int meshConnectedPeers,
  required bool meshRunning,
  required bool? hasNetwork,
  required LocationStatus locationStatus,
}) {
  return [
    _location(alert, locationStatus),
    _mesh(meshPeersReached, meshConnectedPeers, meshRunning),
    _server(entry, hasNetwork),
  ];
}

SosStatusLine _location(SosAlert alert, LocationStatus status) {
  if (alert.latitude != null && alert.longitude != null) {
    final accuracy = alert.locationAccuracyM;
    return SosStatusLine(
      label: 'Location',
      value: 'Included: ${alert.latitude!.toStringAsFixed(5)}, ${alert.longitude!.toStringAsFixed(5)}'
          '${accuracy != null ? ' (±${accuracy.round()} m)' : ''}',
      tone: SosStatusTone.good,
    );
  }
  switch (status) {
    case LocationStatus.permissionDenied:
    case LocationStatus.permissionDeniedForever:
      return const SosStatusLine(
        label: 'Location',
        value: 'Not included — location permission is off',
        tone: SosStatusTone.problem,
        action: SosStatusAction.openLocationSettings,
      );
    case LocationStatus.serviceDisabled:
      return const SosStatusLine(
        label: 'Location',
        value: 'Not included — location services are turned off',
        tone: SosStatusTone.problem,
        action: SosStatusAction.openLocationSettings,
      );
    default:
      return const SosStatusLine(
        label: 'Location',
        value: 'Not included — no GPS fix was available',
        tone: SosStatusTone.problem,
      );
  }
}

SosStatusLine _mesh(int reached, int connected, bool running) {
  if (reached > 0) {
    return SosStatusLine(
      label: 'Nearby devices',
      value: 'Handed to $reached nearby ResQNet ${reached == 1 ? 'device' : 'devices'} over the offline mesh'
          '${connected == 0 ? ' · looking for more' : ''}',
      tone: SosStatusTone.good,
    );
  }
  if (!running) {
    return const SosStatusLine(
      label: 'Nearby devices',
      value: 'Offline mesh is not running — check Bluetooth and nearby-device permissions',
      tone: SosStatusTone.problem,
    );
  }
  return const SosStatusLine(
    label: 'Nearby devices',
    value: 'No ResQNet device in range yet — it will be sent automatically when one is found',
    tone: SosStatusTone.pending,
  );
}

SosStatusLine _server(EmergencyOutboxEntry? entry, bool? hasNetwork) {
  if (entry == null) {
    return const SosStatusLine(label: 'ResQNet server', value: 'Preparing…', tone: SosStatusTone.pending);
  }
  switch (entry.state) {
    case OutboxEntryState.serverAccepted:
    case OutboxEntryState.deliveryConfirmed:
      return const SosStatusLine(
        label: 'ResQNet server',
        value: 'Received — the server alerts your trusted contacts who use ResQNet',
        tone: SosStatusTone.good,
      );
    case OutboxEntryState.serverPending:
      return const SosStatusLine(label: 'ResQNet server', value: 'Sending…', tone: SosStatusTone.pending);
    case OutboxEntryState.failed:
      final unauthorized = entry.lastError?.startsWith('UNAUTHORIZED') ?? false;
      return SosStatusLine(
        label: 'ResQNet server',
        value: unauthorized
            ? 'Not signed in to the ResQNet server — nearby devices and SMS still work'
            : 'The server could not accept this SOS — nearby devices and SMS still work',
        tone: SosStatusTone.problem,
      );
    case OutboxEntryState.expired:
      return const SosStatusLine(
        label: 'ResQNet server',
        value: 'Not delivered before it expired',
        tone: SosStatusTone.problem,
      );
    case OutboxEntryState.cancelledBeforeUpload:
      return const SosStatusLine(label: 'ResQNet server', value: 'Not sent (cancelled)', tone: SosStatusTone.good);
    case OutboxEntryState.created:
    case OutboxEntryState.queued:
    case OutboxEntryState.discovering:
    case OutboxEntryState.sentToPeer:
    case OutboxEntryState.relayed:
      return SosStatusLine(
        label: 'ResQNet server',
        value: hasNetwork == false
            ? 'No internet — will send automatically when a connection returns'
            : entry.attempts > 0
                ? 'Could not reach the server yet — retrying automatically'
                : 'Waiting to send…',
        tone: SosStatusTone.pending,
      );
  }
}

/// How a finished SOS's cancellation stands, for history/detail screens.
String describeResolution(EmergencyOutboxEntry entry) {
  final what = entry.resolution == SosResolution.falseAlarm ? 'Cancelled — false alarm' : 'Resolved — marked safe';
  switch (entry.resolutionSync) {
    case ResolutionSyncState.synced:
      return '$what · server updated';
    case ResolutionSyncState.pending:
      return '$what · server will be updated when online';
    case ResolutionSyncState.notNeeded:
    case ResolutionSyncState.none:
      return what;
  }
}

String formatElapsed(Duration elapsed) {
  if (elapsed.inMinutes < 1) return '${elapsed.inSeconds}s';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ${elapsed.inMinutes % 60}m';
  return '${elapsed.inDays}d ${elapsed.inHours % 24}h';
}
