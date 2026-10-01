import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/emergency_outbox_entry.dart';
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
/// What a dispatch actually did — reported to the UI as-is, never
/// embellished.
class SosDispatchResult {
  const SosDispatchResult({
    required this.alert,
    required this.alreadyActive,
    required this.smsRecipientCount,
  });

  final SosAlert alert;

  /// True when an SOS was already active: nothing new was sent (duplicate
  /// protection), the existing SOS continues.
  final bool alreadyActive;

  /// How many numbers the pre-filled SMS was opened for. The user still has
  /// to press send in their SMS app — this is not a delivery count.
  final int smsRecipientCount;
}

/// The app-lifetime services an SOS dispatch needs, captured synchronously
/// from a [BuildContext] BEFORE any await. Dispatch and cancellation then
/// never touch a widget's context again, so an SOS already confirmed (or a
/// crash/earthquake auto-SOS whose countdown finished) is still sent even if
/// the dialog or screen that started it is disposed mid-send.
class SosDispatchDeps {
  const SosDispatchDeps({
    required this.sos,
    required this.mesh,
    required this.trustedContacts,
    required this.emergencyContacts,
    required this.profile,
  });

  factory SosDispatchDeps.of(BuildContext context) => SosDispatchDeps(
        sos: context.read<SosService>(),
        mesh: context.read<MeshService>(),
        trustedContacts: context.read<TrustedContactsService>(),
        emergencyContacts: context.read<EmergencyContactsService>(),
        profile: context.read<ProfileService>(),
      );

  final SosService sos;
  final MeshService mesh;
  final TrustedContactsService trustedContacts;
  final EmergencyContactsService emergencyContacts;
  final ProfileService profile;
}

class SosDispatchService {
  /// Convenience for callers with a live context and no await before this
  /// call. Anything that awaits first must capture [SosDispatchDeps] up
  /// front and use [dispatchWith].
  static Future<SosDispatchResult> dispatch(
    BuildContext context, {
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
    int? batteryLevel,
    String eventSource = 'manual',
  }) =>
      dispatchWith(
        SosDispatchDeps.of(context),
        userId: userId,
        userName: userName,
        category: category,
        message: message,
        batteryLevel: batteryLevel,
        eventSource: eventSource,
      );

  static Future<SosDispatchResult> dispatchWith(
    SosDispatchDeps deps, {
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
    int? batteryLevel,
    String eventSource = 'manual',
    // Opted-in medical details for an automatic SOS; signed with the SOS
    // (SosService) and never put in the SMS below.
    String medicalSummary = '',
  }) async {
    final sosService = deps.sos;
    final meshService = deps.mesh;
    final trustedContacts = deps.trustedContacts;
    final emergencyContacts = deps.emergencyContacts;
    final profile = deps.profile;

    // Duplicate protection: a second trigger while an SOS is active (a
    // repeated tap, or crash/earthquake detection during a manual SOS)
    // re-uses the active SOS instead of alerting everyone twice.
    final existing = sosService.activeAlert;
    if (existing != null) {
      return SosDispatchResult(alert: existing, alreadyActive: true, smsRecipientCount: 0);
    }

    if (profile.country.isEmpty) {
      await profile.loadProfile();
    }

    // 1. Persist + report to the backend (best-effort, retried later), then
    // hand the SOS to the mesh. It is retained for peers that come into
    // range later, which is what makes an offline SOS reach anyone at all.
    final alert = await sosService.triggerSos(
      userId: userId,
      userName: userName,
      category: category,
      message: message,
      eventSource: eventSource,
      medicalSummary: medicalSummary,
    );
    final signedMsg = await sosService.sosToBroadcastMessage(alert, userName);
    final broadcastMsg = signedMsg.copyWith(batteryLevel: batteryLevel);
    await meshService.broadcastMessage(broadcastMsg, retainForNewPeers: true);

    // 2. Local police / disaster management hotline for the user's
    // country — prefer the Profile's saved country (instant, no GPS wait)
    // and fall back to GPS-based detection only if that isn't set.
    try {
      if (profile.country.isNotEmpty) {
        await emergencyContacts.loadForCountryName(profile.country);
      } else if (emergencyContacts.contacts.isEmpty) {
        await emergencyContacts.detectAndLoadContacts();
      }
    } catch (e) {
      debugPrint('Emergency hotline lookup failed: $e');
    }
    final hotlineNumbers = emergencyContacts.contacts
        .where((c) => c.name.toLowerCase().contains('police') || c.name.toLowerCase().contains('disaster'))
        .map((c) => c.number)
        .toSet()
        .toList();
    final trustedNumbers = trustedContacts.contacts.map((c) => c.phone).toSet().toList();

    // 3. Trusted contacts (parents/relatives) + the hotline, both via one
    // pre-filled SMS — the only channel that reaches non-ResQNet numbers
    // and works purely on cellular signal, online or offline.
    final recipients = <String>{...trustedNumbers, ...hotlineNumbers}.toList();
    if (recipients.isEmpty) {
      return SosDispatchResult(alert: alert, alreadyActive: false, smsRecipientCount: 0);
    }

    final smsBody = sosSmsBody(alert: alert, userName: userName, baseMessage: message);

    final opened = await _sendSms(numbers: recipients, body: smsBody);
    return SosDispatchResult(
      alert: alert,
      alreadyActive: false,
      smsRecipientCount: opened ? recipients.length : 0,
    );
  }

  /// Ends the active SOS: updates local state, tells nearby devices over
  /// the mesh (a signed notice, re-sent to peers that come into range), and
  /// tells the backend now or once online. Returns null if no SOS is active.
  static Future<SosCancelOutcome?> cancel(
    BuildContext context, {
    required SosResolution resolution,
    required String senderName,
  }) =>
      cancelWith(SosDispatchDeps.of(context), resolution: resolution, senderName: senderName);

  static Future<SosCancelOutcome?> cancelWith(
    SosDispatchDeps deps, {
    required SosResolution resolution,
    required String senderName,
  }) async {
    final sosService = deps.sos;
    final meshService = deps.mesh;
    final alert = sosService.activeAlert;
    if (alert == null) return null;

    final outcome = await sosService.cancelActiveSos(resolution);
    meshService.releaseRetained(alert.id);
    try {
      final notice = await sosService.cancellationBroadcastMessage(alert, senderName, resolution);
      await meshService.broadcastMessage(notice, retainForNewPeers: true);
    } catch (e) {
      debugPrint('Mesh cancellation notice failed: $e');
    }
    return outcome;
  }

  /// Re-offers a restored active SOS (after an app restart) to nearby
  /// devices, so it keeps reaching peers that come into range.
  static Future<void> resumeActive(SosService sosService, MeshService meshService) async {
    final alert = sosService.activeAlert;
    if (alert == null) return;
    final message = await sosService.sosToBroadcastMessage(alert, alert.userName);
    await meshService.retainOwnMessage(message);
  }

  /// The pre-filled SMS text. Built from [baseMessage] — what the caller
  /// passed in — never from `alert.message`, which for an opted-in
  /// automatic SOS also carries the signed medical summary: SMS goes
  /// through the carrier unprotected and to hotline numbers, so medical
  /// details are never put in it.
  @visibleForTesting
  static String sosSmsBody({required SosAlert alert, required String userName, required String baseMessage}) {
    final locationLink = alert.latitude != null && alert.longitude != null
        ? 'https://maps.google.com/?q=${alert.latitude},${alert.longitude}'
        : 'location unavailable';
    return 'EMERGENCY (${alert.category.name.toUpperCase()}): $userName needs help. '
        '${baseMessage.isNotEmpty ? '$baseMessage ' : ''}Location: $locationLink '
        '— sent via ResQNet';
  }

  static Future<bool> _sendSms({
    required List<String> numbers,
    required String body,
  }) async {
    final uri = Uri(
      scheme: 'sms',
      path: numbers.join(','),
      queryParameters: {'body': body},
    );
    try {
      return await launchUrl(uri);
    } catch (e) {
      debugPrint('SOS SMS launch error: $e');
      return false;
    }
  }
}
