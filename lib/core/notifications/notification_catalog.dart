import 'dart:convert';
import '../models/emergency_message.dart';

/// Every kind of notification ResQNet shows. Each maps to one channel,
/// one priority, and one deep-link target — see [NotificationSpec].
enum ResQNetNotificationKind {
  /// Someone nearby needs help — received over the offline mesh.
  meshSos,

  /// A trusted contact's SOS, pushed by the backend.
  trustedContactSos,

  /// An SOS near this user, pushed by the backend (no reporter identity).
  nearbySos,

  /// An SOS this user was alerted about has been resolved/cancelled.
  sosResolved,

  /// Crash or earthquake detected on this device: auto-SOS countdown.
  detectionWarning,

  /// Earthquake corroborated by several ResQNet devices.
  earthquakeAlert,

  /// A hazard (flood, fire, …) or other non-SOS mesh alert.
  hazardAlert,

  /// A chat message.
  message,

  /// Anything else the backend sends without a recognised type.
  general,
}

/// Android notification channels. Ids are stable — Android keeps a
/// channel's user settings by id, so they must never be renamed.
class ResQNetChannel {
  const ResQNetChannel(this.id, this.name, this.description, this.level);

  final String id;
  final String name;
  final String description;
  final NotificationLevel level;

  static const sos = ResQNetChannel(
    'resqnet_sos',
    'SOS alerts',
    'Someone near you or one of your trusted contacts needs help',
    NotificationLevel.critical,
  );

  /// Kept on the id the app has always used, so existing installs keep
  /// their settings for it.
  static const detection = ResQNetChannel(
    'resqnet_emergency',
    'Crash & earthquake detection',
    'Automatic SOS countdown after a detected crash or earthquake',
    NotificationLevel.critical,
  );

  static const alerts = ResQNetChannel(
    'resqnet_alerts',
    'Hazard & earthquake alerts',
    'Earthquakes and hazards reported near you',
    NotificationLevel.high,
  );

  static const updates = ResQNetChannel(
    'resqnet_updates',
    'SOS updates',
    'An emergency you were alerted about was resolved or cancelled',
    NotificationLevel.normal,
  );

  static const messages = ResQNetChannel(
    'resqnet_messages',
    'Messages',
    'Messages from your ResQNet contacts',
    NotificationLevel.normal,
  );

  static const all = [sos, detection, alerts, updates, messages];
}

enum NotificationLevel { critical, high, normal }

/// Where tapping a notification leads.
enum NotificationDestination {
  /// Detail of an emergency received over the mesh (by event id).
  meshEmergency,

  /// Detail built from a backend push (trusted-contact SOS, earthquake).
  alertDetail,

  /// The backend's privacy-limited nearby-emergency view.
  nearbyEmergency,

  /// This user's own active SOS.
  ownSos,

  /// The conversations list.
  messages,

  /// Home (used only when nothing more specific exists).
  home,
}

/// A fully resolved notification: what to show, where, and where it leads.
class NotificationSpec {
  const NotificationSpec({
    required this.kind,
    required this.channel,
    required this.title,
    required this.body,
    required this.dedupKey,
    required this.destination,
    this.params = const {},
    String? tag,
  }) : tag = tag ?? dedupKey;

  final ResQNetNotificationKind kind;
  final ResQNetChannel channel;
  final String title;
  final String body;

  /// Identifies the underlying event, so the same emergency arriving by
  /// mesh, push, and realtime socket produces one notification, not three.
  final String dedupKey;
  final NotificationDestination destination;

  /// Deep-link parameters (ids, coordinates). Only validated values.
  final Map<String, String> params;

  /// Display slot (Android notification tag). Matches the tag the backend
  /// puts on its pushes (`sos:<eventId>`), so the pushed and mesh copies of
  /// one SOS occupy one notification, and a later "resolved" update
  /// replaces the original alert.
  final String tag;

  /// Stable per-event notification id: re-showing the same event replaces
  /// the existing notification instead of stacking a new one.
  int get notificationId => stableNotificationId(tag);

  String get payload => jsonEncode({'destination': destination.name, ...params});
}

final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Notification and push payloads are untrusted input: ids are only used
/// if they are well-formed UUIDs.
String? validUuid(Object? value) => value is String && _uuidPattern.hasMatch(value) ? value : null;

String? _validCoordinate(Object? value, double limit) {
  final parsed = value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
  if (parsed == null || parsed.isNaN || parsed.abs() > limit) return null;
  return parsed.toString();
}

String _clip(String text, int max) => text.length <= max ? text : '${text.substring(0, max - 1)}…';

/// 31-bit FNV-1a hash — stable across runs (unlike `String.hashCode`),
/// positive, and within Android's int notification-id range.
int stableNotificationId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(key)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Maps a backend push (FCM `data` + notification text) to a spec.
/// Returns null for a payload that should not be shown (e.g. malformed).
NotificationSpec? specForPush(Map<String, dynamic> data, {String? title, String? body}) {
  final type = data['type'] as String?;
  final sosEventId = validUuid(data['sosEventId']);
  final eventId = validUuid(data['eventId']);
  // The client eventId is shared with the mesh copy of the same SOS, so it
  // is preferred as the dedup key.
  final eventKey = eventId ?? sosEventId;

  switch (type) {
    case 'sos_trusted_contact':
      if (eventKey == null) return null;
      final lat = _validCoordinate(data['latitude'], 90);
      final lng = _validCoordinate(data['longitude'], 180);
      return NotificationSpec(
        kind: ResQNetNotificationKind.trustedContactSos,
        channel: ResQNetChannel.sos,
        title: title ?? '🚨 A trusted contact needs help',
        body: body ?? 'Open ResQNet for their location.',
        dedupKey: 'sos:$eventKey',
        destination: NotificationDestination.alertDetail,
        params: {
          'alert': 'trusted_contact_sos',
          if (sosEventId != null) 'sosEventId': sosEventId,
          'title': _clip(title ?? 'A trusted contact needs help', 120),
          'body': _clip(body ?? '', 500),
          if (lat != null && lng != null) 'latitude': lat,
          if (lat != null && lng != null) 'longitude': lng,
        },
      );
    case 'sos_nearby':
      if (sosEventId == null) return null;
      return NotificationSpec(
        kind: ResQNetNotificationKind.nearbySos,
        channel: ResQNetChannel.sos,
        title: title ?? '🚨 Emergency nearby',
        body: body ?? 'Someone near you needs help.',
        dedupKey: 'sos:$eventKey',
        destination: NotificationDestination.nearbyEmergency,
        params: {'sosEventId': sosEventId},
      );
    case 'sos_resolved':
      if (eventKey == null) return null;
      return NotificationSpec(
        kind: ResQNetNotificationKind.sosResolved,
        channel: ResQNetChannel.updates,
        title: title ?? '✅ Emergency resolved',
        body: body ?? 'No further action is needed for this alert.',
        dedupKey: 'sos-resolved:$eventKey',
        tag: 'sos:$eventKey',
        destination: NotificationDestination.home,
      );
    case 'earthquake_corroborated':
      final lat = _validCoordinate(data['latitude'], 90);
      final lng = _validCoordinate(data['longitude'], 180);
      final bucket = DateTime.now().toUtc().toIso8601String().substring(0, 13);
      return NotificationSpec(
        kind: ResQNetNotificationKind.earthquakeAlert,
        channel: ResQNetChannel.alerts,
        title: title ?? '🌍 Possible earthquake detected',
        body: body ?? 'Reported by several ResQNet devices in your area.',
        // One alert per area per hour, however many devices corroborate it.
        dedupKey: 'quake:${lat ?? '?'}:${lng ?? '?'}:$bucket',
        destination: NotificationDestination.alertDetail,
        params: {
          'alert': 'earthquake',
          'title': _clip(title ?? 'Possible earthquake detected', 120),
          'body': _clip(body ?? '', 500),
          if (lat != null && lng != null) 'latitude': lat,
          if (lat != null && lng != null) 'longitude': lng,
        },
      );
    default:
      // Legacy payloads without a type: an SOS id still identifies it.
      if (sosEventId != null) {
        return NotificationSpec(
          kind: ResQNetNotificationKind.nearbySos,
          channel: ResQNetChannel.sos,
          title: title ?? '🚨 Emergency',
          body: body ?? 'Open ResQNet for details.',
          dedupKey: 'sos:$eventKey',
          destination: NotificationDestination.nearbyEmergency,
          params: {'sosEventId': sosEventId},
        );
      }
      if (title == null && body == null) return null;
      return NotificationSpec(
        kind: ResQNetNotificationKind.general,
        channel: ResQNetChannel.updates,
        title: title ?? 'ResQNet',
        body: body ?? '',
        dedupKey: 'general:${stableNotificationId('${title ?? ''}|${body ?? ''}')}',
        destination: NotificationDestination.home,
      );
  }
}

/// Maps a message received over the mesh to a spec, or null when it should
/// not raise a notification (low-priority chatter, own messages, …).
NotificationSpec? specForMeshMessage(EmergencyMessage message, {bool cancellationVerified = false}) {
  final eventId = validUuid(message.id);
  if (eventId == null) return null;

  if (message.isCancellation) {
    final target = validUuid(message.cancelsEventId);
    // An unverified cancellation never produces an "all clear".
    if (target == null || !cancellationVerified) return null;
    return NotificationSpec(
      kind: ResQNetNotificationKind.sosResolved,
      channel: ResQNetChannel.updates,
      title: '✅ Nearby SOS cancelled',
      body: _clip(message.message, 200),
      dedupKey: 'sos-resolved:$target',
      tag: 'sos:$target',
      destination: NotificationDestination.meshEmergency,
      params: {'eventId': target},
    );
  }

  final isSos = message.originEnvelope?.eventType == 'sos' ||
      message.priority == PriorityLevel.critical ||
      message.priority == PriorityLevel.high;
  if (isSos) {
    final who = message.senderName.trim().isEmpty ? 'Someone nearby' : _clip(message.senderName.trim(), 40);
    return NotificationSpec(
      kind: ResQNetNotificationKind.meshSos,
      channel: ResQNetChannel.sos,
      title: '🚨 SOS nearby — $who needs help',
      body: _clip(message.message.isEmpty ? 'Received over the ResQNet mesh.' : message.message, 200),
      dedupKey: 'sos:$eventId',
      destination: NotificationDestination.meshEmergency,
      params: {'eventId': eventId},
    );
  }
  if (message.priority == PriorityLevel.medium) {
    return NotificationSpec(
      kind: ResQNetNotificationKind.hazardAlert,
      channel: ResQNetChannel.alerts,
      title: '⚠️ Alert from a nearby device',
      body: _clip(message.message, 200),
      dedupKey: 'mesh:$eventId',
      destination: NotificationDestination.meshEmergency,
      params: {'eventId': eventId},
    );
  }
  // Low priority ("I am safe", informational) — visible in the app only.
  return null;
}

/// Spec for this device's own crash/earthquake auto-SOS countdown, shown
/// so the user can cancel it even when the app is in the background.
NotificationSpec detectionWarningSpec({required String detection, required int seconds}) {
  final bucket = DateTime.now().toUtc().toIso8601String().substring(0, 16);
  return NotificationSpec(
    kind: ResQNetNotificationKind.detectionWarning,
    channel: ResQNetChannel.detection,
    title: detection == 'earthquake' ? '🌍 Earthquake detected' : '🚗 Possible crash detected',
    body: 'SOS will be sent automatically in about $seconds seconds. Open ResQNet to cancel.',
    dedupKey: 'detection:$detection:$bucket',
    destination: NotificationDestination.home,
  );
}

/// Parses a tapped notification's payload back into a destination and
/// validated parameters. Anything unrecognised opens Home.
({NotificationDestination destination, Map<String, String> params}) parseNotificationPayload(String? payload) {
  const fallback = (destination: NotificationDestination.home, params: <String, String>{});
  if (payload == null || payload.isEmpty) return fallback;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return fallback;
    final destination = NotificationDestination.values.where((d) => d.name == decoded['destination']).firstOrNull;
    if (destination == null) return fallback;
    final params = <String, String>{
      for (final entry in decoded.entries)
        if (entry.key != 'destination' && entry.value is String) entry.key as String: entry.value as String,
    };
    return (destination: destination, params: params);
  } catch (_) {
    return fallback;
  }
}
