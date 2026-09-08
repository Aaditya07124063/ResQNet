// Tests for the trust-tier model (emergency_communication_service.dart's
// EmergencyTrustTier/trustTierLabelFor/trustTierForBackendRecord/
// trustTierFor/trustTierForReceivedMessage) and its ONE shared rendering
// widget (widgets/trust_tier_badge.dart's TrustTierBadge) — the
// requirement that every screen show exactly one of four labels
// (UNVERIFIED / ORIGIN VERIFIED / BACKEND VERIFIED / DELIVERY CONFIRMED)
// and never a screen-invented synonym.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/services/ai_service.dart';
import 'package:resqnet/core/services/emergency_communication_service.dart';
import 'package:resqnet/core/services/voice_note_service.dart';
import 'package:resqnet/widgets/emergency_card.dart';
import 'package:resqnet/widgets/trust_tier_badge.dart';

EmergencyOutboxEntry _outboxEntry({
  required OutboxEntryState state,
  OriginEnvelope? originEnvelope,
  String? serverOriginVerificationState,
}) =>
    EmergencyOutboxEntry(
      eventId: 'evt-1',
      eventSource: 'manual',
      category: 'medical',
      createdAt: DateTime.now(),
      state: state,
      originEnvelope: originEnvelope,
      serverOriginVerificationState: serverOriginVerificationState,
    );

OriginEnvelope _envelope() => OriginEnvelope(
      protocolVersion: '1',
      originDeviceId: 'device-A',
      eventType: 'sos',
      eventSource: 'manual',
      category: 'medical',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
      maxHops: 8,
      priority: 'critical',
      keyId: 'key-1',
      signature: 'sig',
    );

EmergencyMessage _receivedMessage({OriginEnvelope? envelope, bool originVerifiedLocally = false}) => EmergencyMessage(
      id: 'evt-1',
      senderId: 'device-A',
      senderName: 'Hiker A',
      message: 'help',
      type: EmergencyType.trapped,
      priority: PriorityLevel.critical,
      timestamp: DateTime.now(),
      originEnvelope: envelope,
      originVerifiedLocally: originVerifiedLocally,
    );

void main() {
  group('EmergencyTrustTier -> TrustTierLabel mapping (exactly 4 labels)', () {
    test('transportOnly, signaturePresentUnverified, and backendAcceptedUnverifiedOrigin all map to unverified', () {
      expect(trustTierLabelFor(EmergencyTrustTier.transportOnly), TrustTierLabel.unverified);
      expect(trustTierLabelFor(EmergencyTrustTier.signaturePresentUnverified), TrustTierLabel.unverified);
      expect(trustTierLabelFor(EmergencyTrustTier.backendAcceptedUnverifiedOrigin), TrustTierLabel.unverified);
    });

    test('originVerifiedLocally maps to originVerified', () {
      expect(trustTierLabelFor(EmergencyTrustTier.originVerifiedLocally), TrustTierLabel.originVerified);
    });

    test('originVerifiedByBackend maps to backendVerified', () {
      expect(trustTierLabelFor(EmergencyTrustTier.originVerifiedByBackend), TrustTierLabel.backendVerified);
    });

    test('deliveryConfirmed maps to deliveryConfirmed', () {
      expect(trustTierLabelFor(EmergencyTrustTier.deliveryConfirmed), TrustTierLabel.deliveryConfirmed);
    });
  });

  group('trustTierForBackendRecord (sos_history_screen.dart\'s REST-fetched records)', () {
    test('"verified" maps to originVerifiedByBackend', () {
      expect(trustTierForBackendRecord('verified'), EmergencyTrustTier.originVerifiedByBackend);
    });
    test('"unverified_unregistered" maps to backendAcceptedUnverifiedOrigin', () {
      expect(trustTierForBackendRecord('unverified_unregistered'), EmergencyTrustTier.backendAcceptedUnverifiedOrigin);
    });
    test('"not_applicable" and null render no badge at all', () {
      expect(trustTierForBackendRecord('not_applicable'), null);
      expect(trustTierForBackendRecord(null), null);
    });
  });

  group('trustTierFor (EmergencyOutboxEntry — this device\'s own sent SOS)', () {
    test('no envelope, not yet synced -> transportOnly', () {
      expect(trustTierFor(_outboxEntry(state: OutboxEntryState.queued)), EmergencyTrustTier.transportOnly);
    });
    test('signed envelope, not yet synced -> signaturePresentUnverified', () {
      expect(
        trustTierFor(_outboxEntry(state: OutboxEntryState.queued, originEnvelope: _envelope())),
        EmergencyTrustTier.signaturePresentUnverified,
      );
    });
    test('server accepted with verified origin -> originVerifiedByBackend', () {
      expect(
        trustTierFor(_outboxEntry(state: OutboxEntryState.serverAccepted, serverOriginVerificationState: 'verified')),
        EmergencyTrustTier.originVerifiedByBackend,
      );
    });
    test('server accepted without verified origin -> backendAcceptedUnverifiedOrigin', () {
      expect(
        trustTierFor(_outboxEntry(state: OutboxEntryState.serverAccepted)),
        EmergencyTrustTier.backendAcceptedUnverifiedOrigin,
      );
    });
    test('deliveryConfirmed state -> deliveryConfirmed tier (reserved, not reachable in production yet)', () {
      expect(trustTierFor(_outboxEntry(state: OutboxEntryState.deliveryConfirmed)), EmergencyTrustTier.deliveryConfirmed);
    });
  });

  group('trustTierForReceivedMessage (mesh-received EmergencyMessage)', () {
    test('no envelope -> transportOnly', () {
      expect(trustTierForReceivedMessage(_receivedMessage()), EmergencyTrustTier.transportOnly);
    });
    test('envelope present but not locally verified -> signaturePresentUnverified', () {
      expect(
        trustTierForReceivedMessage(_receivedMessage(envelope: _envelope())),
        EmergencyTrustTier.signaturePresentUnverified,
      );
    });
    test('originVerifiedLocally true -> originVerifiedLocally tier', () {
      expect(
        trustTierForReceivedMessage(_receivedMessage(envelope: _envelope(), originVerifiedLocally: true)),
        EmergencyTrustTier.originVerifiedLocally,
      );
    });
  });

  group('TrustTierBadge widget renders exactly the required label text', () {
    Future<void> pumpBadge(WidgetTester tester, EmergencyTrustTier tier) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TrustTierBadge(tier: tier))),
        );

    testWidgets('unverified tiers render "UNVERIFIED"', (tester) async {
      await pumpBadge(tester, EmergencyTrustTier.transportOnly);
      expect(find.text('UNVERIFIED'), findsOneWidget);
    });

    testWidgets('originVerifiedLocally renders "ORIGIN VERIFIED"', (tester) async {
      await pumpBadge(tester, EmergencyTrustTier.originVerifiedLocally);
      expect(find.text('ORIGIN VERIFIED'), findsOneWidget);
    });

    testWidgets('originVerifiedByBackend renders "BACKEND VERIFIED"', (tester) async {
      await pumpBadge(tester, EmergencyTrustTier.originVerifiedByBackend);
      expect(find.text('BACKEND VERIFIED'), findsOneWidget);
    });

    testWidgets('deliveryConfirmed renders "DELIVERY CONFIRMED"', (tester) async {
      await pumpBadge(tester, EmergencyTrustTier.deliveryConfirmed);
      expect(find.text('DELIVERY CONFIRMED'), findsOneWidget);
    });

    testWidgets('tapping the badge opens an explanation dialog naming the same label', (tester) async {
      await pumpBadge(tester, EmergencyTrustTier.originVerifiedLocally);
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(find.text('ORIGIN VERIFIED'), findsWidgets); // badge label + dialog title
      expect(find.textContaining('does NOT'), findsOneWidget);
    });
  });

  group('EmergencyCard shows the correct trust tier for a received mesh message', () {
    Future<void> pumpCard(WidgetTester tester, EmergencyMessage message) => tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AiService()),
              ChangeNotifierProvider(create: (_) => VoiceNoteService()),
            ],
            child: MaterialApp(home: Scaffold(body: EmergencyCard(message: message))),
          ),
        );

    testWidgets('a message with no envelope shows UNVERIFIED', (tester) async {
      await pumpCard(tester, _receivedMessage());
      expect(find.text('UNVERIFIED'), findsOneWidget);
    });

    testWidgets('a message the mesh layer locally verified shows ORIGIN VERIFIED', (tester) async {
      await pumpCard(tester, _receivedMessage(envelope: _envelope(), originVerifiedLocally: true));
      expect(find.text('ORIGIN VERIFIED'), findsOneWidget);
    });
  });
}
