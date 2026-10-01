import 'package:flutter/material.dart';
import '../../core/notifications/notification_catalog.dart';
import '../../core/services/notification_service.dart';
import '../communication/conversations_list_screen.dart';
import '../emergency/alert_detail_screen.dart';
import '../emergency/nearby_emergency_screen.dart';
import '../emergency/received_emergency_screen.dart';
import '../sos/active_sos_screen.dart';

/// Opens the screen a tapped notification points to. Parameters come from
/// untrusted payloads and are re-validated here; anything invalid simply
/// stays on Home.
void openNotificationDestination(BuildContext context, NotificationTap tap) {
  Widget? screen;
  switch (tap.destination) {
    case NotificationDestination.meshEmergency:
      final eventId = validUuid(tap.params['eventId']);
      if (eventId != null) screen = ReceivedEmergencyScreen(eventId: eventId);
    case NotificationDestination.nearbyEmergency:
      final sosEventId = validUuid(tap.params['sosEventId']);
      if (sosEventId != null) screen = NearbyEmergencyScreen(sosEventId: sosEventId);
    case NotificationDestination.alertDetail:
      screen = AlertDetailScreen(params: tap.params);
    case NotificationDestination.ownSos:
      screen = const ActiveSosScreen();
    case NotificationDestination.messages:
      screen = const ConversationsListScreen();
    case NotificationDestination.home:
      screen = null;
  }
  if (screen == null) return;
  final target = screen;
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => target));
}
