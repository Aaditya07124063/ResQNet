import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/sos_alert.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/services/ai_service.dart';
import 'package:resqnet/core/services/connectivity_status_service.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'package:resqnet/core/services/emergency_contacts_service.dart';
import 'package:resqnet/core/services/profile_service.dart';
import 'package:resqnet/core/services/trusted_contacts_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/location_service.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'package:resqnet/core/services/sos_service.dart';
import 'package:resqnet/features/home/widgets/sos_home_panel.dart';
import 'package:resqnet/features/sos/sos_actions.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late FakeSecureStorage secureStorage;
  late FakeDeviceKeyChannel keys;
  late SosService sos;
  late MeshService mesh;
  late ConnectivityStatusService connectivity;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    keys = FakeDeviceKeyChannel();
    DeviceKeyService.instance.resetCacheForTests();
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => throw Exception('offline')));
    sos = SosService(AiService(), LocationService(), restoreOnCreate: false);
    mesh = MeshService(testOutboxStore: EmergencyOutboxStore(keyPrefix: 'widget-'), testDeviceId: 'self');
    connectivity = ConnectivityStatusService()..setForTesting(false);
  });

  tearDown(() {
    keys.dispose();
    secureStorage.dispose();
    DeviceKeyService.instance.resetCacheForTests();
    ApiClient.instance = ApiClient();
  });

  Widget app({double textScale = 1.0}) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: sos),
          ChangeNotifierProvider.value(value: mesh),
          ChangeNotifierProvider(create: (_) => LocationService()),
          ChangeNotifierProvider.value(value: connectivity),
          // Captured by startSos before the countdown, as in the app.
          ChangeNotifierProvider(create: (_) => TrustedContactsService()),
          ChangeNotifierProvider(create: (_) => EmergencyContactsService()),
          ChangeNotifierProvider(create: (_) => ProfileService()),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale), size: const Size(390, 844)),
            child: const Scaffold(body: SingleChildScrollView(child: SosHomePanel())),
          ),
        ),
      );

  testWidgets('Home shows a large, labelled SOS control first', (tester) async {
    await tester.pumpWidget(app());
    final button = find.byKey(const Key('home-sos-button'));
    expect(button, findsOneWidget);
    expect(tester.getSize(button).width, greaterThanOrEqualTo(180));
    expect(find.text('SOS'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^SOS\. Send emergency alert\. Starts a 5 second countdown')),
      findsOneWidget,
    );
  });

  testWidgets('network state is shown in words, not colour alone', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('Unavailable'), findsOneWidget); // internet
    expect(find.text('Off'), findsOneWidget); // mesh not started in tests
  });

  testWidgets('tapping SOS starts a countdown; Cancel sends nothing', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('home-sos-button')));
    await tester.pump();

    expect(find.byKey(const Key('sos-countdown-value')), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos-countdown-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sos-countdown-value')), findsNothing);
    expect(sos.sosActive, isFalse);
    expect(find.byKey(const Key('home-sos-button')), findsOneWidget);
  });

  testWidgets('the countdown sends automatically after 5 seconds, and "Send now" skips it', (tester) async {
    bool? auto;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    showSosCountdown(ctx).then((r) => auto = r);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(auto, isNull);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(auto, isTrue);

    bool? now;
    showSosCountdown(ctx).then((r) => now = r);
    await tester.pump();
    await tester.tap(find.byKey(const Key('sos-countdown-send-now')));
    await tester.pumpAndSettle();
    expect(now, isTrue);
  });

  testWidgets('an active SOS replaces the button with live status and an "I\'m safe" action', (tester) async {
    await tester.runAsync(() => sos.triggerSos(
          userId: 'u',
          userName: 'Hiker A',
          category: SosCategory.trapped,
          message: 'stuck',
        ));
    await tester.pumpWidget(app());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.byKey(const Key('home-sos-button')), findsNothing);
    expect(find.byKey(const Key('active-sos-card')), findsOneWidget);
    expect(find.text('SOS ACTIVE'), findsOneWidget);
    expect(find.text('Nearby devices'), findsOneWidget);
    expect(find.text('ResQNet server'), findsOneWidget);
    expect(find.textContaining('No internet'), findsOneWidget);
    expect(find.byKey(const Key('active-sos-end')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^SOS active for')), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // stop the 1s ticker
  });

  testWidgets('the SOS panel does not overflow at 200% text size', (tester) async {
    await tester.pumpWidget(app(textScale: 2.0));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('home-sos-button')), findsOneWidget);
  });

  testWidgets('the active SOS card does not overflow at 200% text size', (tester) async {
    await tester.runAsync(() => sos.triggerSos(
          userId: 'u',
          userName: 'Hiker A',
          category: SosCategory.trapped,
          message: 'stuck',
        ));
    await tester.pumpWidget(app(textScale: 2.0));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('SOS ACTIVE'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
