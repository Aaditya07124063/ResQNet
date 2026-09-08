import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/sos_alert.dart';
import 'emergency_contacts_service.dart';
import 'mesh_service.dart';
import 'profile_service.dart';
import 'sos_service.dart';
import 'trusted_contacts_service.dart';

/// Single place that answers "who does an SOS actually reach, and how":
///
/// - **Nearby people**: broadcast over the mesh (Bluetooth/Wi-Fi Direct) —
///   works with zero internet, reaches every phone in range immediately.
/// - **Local police / disaster management**: an SMS to the national
///   hotline number for the user's country (from [EmergencyContactsService])
///   — SMS rides the cellular network, not mobile data, so it goes out even
///   fully offline as long as there's carrier signal at all.
/// - **Trusted contacts (parents/relatives)**: same SMS, addressed to
///   whatever numbers the user saved in [TrustedContactsService]. If a
///   contact also uses ResQNet, they additionally get a targeted push
///   once the sender is back online — the ResQNet backend's own
///   `POST /api/v1/sos` handles this fan-out server-side now (Phase 11 +
///   Phase 17's `pushNotificationService.ts`), triggered by
///   [SosService.triggerSos] just above this in the call chain. (Phase
///   20: this used to ALSO write a Firestore `sos_dispatch` record for a
///   Cloud Function to read — removed, now fully superseded; see
///   docs/DONE.md's Phase 20 entry. The "real local police/disaster API"
///   this comment used to describe as a future consumer was never built
///   anywhere in this project — nothing ever read that record besides
///   the now-removed Cloud Function.)
/// - **All other ResQNet users who have internet**: same backend call,
///   broadcast server-side to every other active user's registered
///   devices.
///
/// Honest limitation: Android and iOS do not allow a third-party app to
/// send SMS silently — the OS requires one tap to actually send. This
/// dispatches everything else with zero taps, then opens that one SMS
/// already pre-filled so the tap is the only step left.
class SosDispatchService {
  static Future<void> dispatch(
    BuildContext context, {
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
    int? batteryLevel,
    String eventSource = 'manual',
  }) async {
    final sosService = context.read<SosService>();
    final meshService = context.read<MeshService>();
    final trustedContacts = context.read<TrustedContactsService>();
    final emergencyContacts = context.read<EmergencyContactsService>();
    final profile = context.read<ProfileService>();
    if (profile.country.isEmpty) {
      await profile.loadProfile();
    }

    // 1. Records the event with the backend (trusted-contact + broadcast
    // push fan-out happens server-side, best-effort) and broadcasts over
    // the mesh to nearby offline devices — SosService/MeshService
    // behavior, unchanged except for what "record the event" now means.
    final alert = await sosService.triggerSos(
      userId: userId,
      userName: userName,
      category: category,
      message: message,
      eventSource: eventSource,
    );
    final signedMsg = await sosService.sosToBroadcastMessage(alert, userName);
    final broadcastMsg = signedMsg.copyWith(batteryLevel: batteryLevel);
    await meshService.broadcastMessage(broadcastMsg);

    // 2. Local police / disaster management hotline for the user's
    // country — prefer the Profile's saved country (instant, no GPS wait)
    // and fall back to GPS-based detection only if that isn't set.
    if (profile.country.isNotEmpty) {
      await emergencyContacts.loadForCountryName(profile.country);
    } else if (emergencyContacts.contacts.isEmpty) {
      await emergencyContacts.detectAndLoadContacts();
    }
    final hotlineNumbers = emergencyContacts.contacts
        .where((c) =>
            c.name.toLowerCase().contains('police') ||
            c.name.toLowerCase().contains('disaster'))
        .map((c) => c.number)
        .toSet()
        .toList();
    final trustedNumbers =
        trustedContacts.contacts.map((c) => c.phone).toSet().toList();

    // 3. Trusted contacts (parents/relatives) + the hotline, both via one
    // pre-filled SMS — the only channel that reaches non-ResQNet numbers
    // and works purely on cellular signal, online or offline.
    final recipients = <String>{...trustedNumbers, ...hotlineNumbers}.toList();
    if (recipients.isEmpty) return;

    final locationLink = alert.latitude != null && alert.longitude != null
        ? 'https://maps.google.com/?q=${alert.latitude},${alert.longitude}'
        : 'location unavailable';
    final smsBody =
        'EMERGENCY (${category.name.toUpperCase()}): $userName needs help. '
        '${message.isNotEmpty ? '$message ' : ''}Location: $locationLink '
        '— sent via ResQNet';

    await _sendSms(numbers: recipients, body: smsBody);
  }

  static Future<void> _sendSms({
    required List<String> numbers,
    required String body,
  }) async {
    final uri = Uri(
      scheme: 'sms',
      path: numbers.join(','),
      queryParameters: {'body': body},
    );
    try {
      await launchUrl(uri);
    } catch (e) {
      debugPrint('SOS SMS launch error: $e');
    }
  }
}
