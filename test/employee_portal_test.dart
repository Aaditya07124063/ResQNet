import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resqnet/core/employee/employee_api_client.dart';
import 'package:resqnet/core/employee/employee_session.dart';
import 'package:resqnet/core/employee/employee_token_storage.dart';
import 'package:resqnet/core/employee/sms_provider_admin.dart';
import 'package:resqnet/core/network/api_exception.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/features/employee/employee_portal_screen.dart';
import 'package:resqnet/features/employee/sms_provider_form_screen.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

Map<String, dynamic> meResponse({String role = 'admin', List<String> permissions = const []}) => {
      'employee': {'id': 'e1', 'email': 'ops@resqnet.co', 'displayName': 'Ops', 'role': role},
      'permissions': [
        for (final p in permissions) {'permission': p, 'grantedAt': '2026-01-01T00:00:00.000Z'},
      ],
    };

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() => secureStorage = FakeSecureStorage());
  tearDown(() {
    secureStorage.dispose();
    EmployeeApiClient.instance = EmployeeApiClient();
  });

  group('EmployeeApiClient', () {
    test('uses only employee tokens and the /employee API prefix', () async {
      await TokenStorage.instance.save(accessToken: 'consumer-access', refreshToken: 'consumer-refresh');
      await EmployeeTokenStorage.instance.save(accessToken: 'employee-access', refreshToken: 'employee-refresh');
      final fake = FakeHttpClient((request) async {
        expect(request.url.path, '/api/v1/employee/me');
        expect(request.headers['Authorization'], 'Bearer employee-access');
        return jsonStreamedResponse(200, meResponse());
      });

      await EmployeeApiClient(httpClient: fake).get('/me');
      expect(await TokenStorage.instance.readAccessToken(), 'consumer-access');
    });

    test('concurrent 401s share a single refresh, then retry with the new token', () async {
      await EmployeeTokenStorage.instance.save(accessToken: 'old', refreshToken: 'r1');
      var refreshCalls = 0;
      final fake = FakeHttpClient((request) async {
        if (request.url.path.endsWith('/employee/auth/refresh')) {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return jsonStreamedResponse(200, fakeSession(access: 'new', refresh: 'r2'));
        }
        return request.headers['Authorization'] == 'Bearer new'
            ? jsonStreamedResponse(200, {'ok': true})
            : jsonStreamedResponse(401, {
                'error': {'code': 'UNAUTHORIZED', 'message': 'expired'}
              });
      });
      final client = EmployeeApiClient(httpClient: fake);

      final results = await Future.wait([client.get('/a'), client.get('/b')]);

      expect(results, everyElement({'ok': true}));
      expect(refreshCalls, 1);
      expect(await EmployeeTokenStorage.instance.readRefreshToken(), 'r2');
    });

    test('a rejected refresh clears the employee session but never the consumer one', () async {
      await TokenStorage.instance.save(accessToken: 'consumer-access', refreshToken: 'consumer-refresh');
      await EmployeeTokenStorage.instance.save(accessToken: 'old', refreshToken: 'revoked');
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(401, {
            'error': {'code': 'UNAUTHORIZED', 'message': 'no'}
          }));

      await expectLater(EmployeeApiClient(httpClient: fake).get('/me'), throwsA(isA<ApiException>()));
      expect(await EmployeeTokenStorage.instance.readRefreshToken(), isNull);
      expect(await TokenStorage.instance.readRefreshToken(), 'consumer-refresh');
    });

    test('a network failure during refresh keeps the stored employee tokens', () async {
      await EmployeeTokenStorage.instance.save(accessToken: 'old', refreshToken: 'r1');
      final fake = FakeHttpClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) throw const SocketException('offline');
        return jsonStreamedResponse(401, {
          'error': {'code': 'UNAUTHORIZED', 'message': 'expired'}
        });
      });

      await expectLater(EmployeeApiClient(httpClient: fake).get('/me'), throwsA(isA<ApiException>()));
      expect(await EmployeeTokenStorage.instance.readRefreshToken(), 'r1');
    });
  });

  group('EmployeeSession', () {
    test('restore makes no request when no employee has signed in', () async {
      final fake = FakeHttpClient((_) async => fail('no request expected'));
      final session = EmployeeSession(client: EmployeeApiClient(httpClient: fake));
      await session.restore();
      expect(session.status, EmployeeSessionStatus.signedOut);
      expect(fake.requests, isEmpty);
    });

    test('login stores tokens and loads permissions', () async {
      final fake = FakeHttpClient((request) async {
        if (request.url.path.endsWith('/auth/login')) return jsonStreamedResponse(200, fakeSession());
        return jsonStreamedResponse(200, meResponse(permissions: [smsProviderManagePermission]));
      });
      final session = EmployeeSession(client: EmployeeApiClient(httpClient: fake));

      await session.login('ops@resqnet.co', 'pw');

      expect(session.isSignedIn, isTrue);
      expect(session.can(smsProviderManagePermission), isTrue);
      expect(session.can('EMPLOYEE_MANAGE'), isFalse);
      expect(await EmployeeTokenStorage.instance.readAccessToken(), 'access');
    });

    test('super_admin is treated as holding every permission', () async {
      await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
      final fake = FakeHttpClient((_) async => jsonStreamedResponse(200, meResponse(role: 'super_admin')));
      final session = EmployeeSession(client: EmployeeApiClient(httpClient: fake));
      await session.restore();
      expect(session.can(smsProviderManagePermission), isTrue);
    });

    test('restore while offline keeps tokens and reports offline', () async {
      await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
      final fake = FakeHttpClient((_) async => throw const SocketException('offline'));
      final session = EmployeeSession(client: EmployeeApiClient(httpClient: fake));
      await session.restore();
      expect(session.status, EmployeeSessionStatus.offline);
      expect(await EmployeeTokenStorage.instance.readRefreshToken(), 'r');
    });

    test('logout clears employee tokens even if the server is unreachable', () async {
      await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
      final fake = FakeHttpClient((_) async => throw const SocketException('offline'));
      final session = EmployeeSession(client: EmployeeApiClient(httpClient: fake));
      await session.logout();
      expect(session.status, EmployeeSessionStatus.signedOut);
      expect(await EmployeeTokenStorage.instance.readAccessToken(), isNull);
    });
  });

  group('SmsProviderAdminService', () {
    test('update omits blank secrets and sends blank configuration as null', () async {
      await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
      late Map<String, dynamic> sent;
      final fake = FakeHttpClient((request) async {
        sent = Map<String, dynamic>.from(
          jsonDecode((request as http.Request).body) as Map,
        );
        return jsonStreamedResponse(200, {
          'provider': {'id': 'p1', 'providerType': 'twilio', 'displayName': 'T'},
        });
      });
      final service = SmsProviderAdminService(client: EmployeeApiClient(httpClient: fake));

      await service.update(
        'p1',
        credentials: {'account_sid': '', 'auth_token': 'new-token'},
        configuration: {'from_number': '+15005550006', 'messaging_service_sid': ''},
      );

      expect(sent['credentials'], {'auth_token': 'new-token'});
      expect(sent['configuration'], {'from_number': '+15005550006', 'messaging_service_sid': null});
    });
  });

  group('portal widgets', () {
    Widget wrap(Widget child, EmployeeSession session) => ChangeNotifierProvider<EmployeeSession>.value(
          value: session,
          child: MaterialApp(home: child),
        );

    testWidgets('shows the staff sign-in form when signed out', (tester) async {
      final session = EmployeeSession(client: EmployeeApiClient(httpClient: FakeHttpClient((_) async => fail('none'))));
      await tester.pumpWidget(wrap(const EmployeePortalScreen(), session));
      await tester.pumpAndSettle();
      expect(find.text('Staff sign-in'), findsOneWidget);
      expect(find.byKey(const Key('employee-password')), findsOneWidget);
    });

    testWidgets('shows the SMS providers section only with SMS_PROVIDER_MANAGE', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pumpWith(List<String> permissions) async {
        await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
        final client = EmployeeApiClient(
          httpClient: FakeHttpClient((request) async => request.url.path.endsWith('/employee/me')
              ? jsonStreamedResponse(200, meResponse(role: 'employee', permissions: permissions))
              : jsonStreamedResponse(200, {'providers': []})),
        );
        EmployeeApiClient.instance = client;
        final session = EmployeeSession(client: client);
        await tester.runAsync(session.restore);
        await tester.pumpWidget(wrap(const EmployeePortalScreen(), session));
        await tester.pump();
      }

      await pumpWith([]);
      expect(find.byKey(const Key('ops-nav-sms')), findsNothing);
      await pumpWith([smsProviderManagePermission]);
      expect(find.byKey(const Key('ops-nav-sms')), findsOneWidget);
    });

    testWidgets('provider form never shows stored secrets and does not require re-entering them', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const type = SmsProviderType(
        providerType: 'sparrow_sms',
        displayName: 'Sparrow SMS',
        available: true,
        coverage: 'Nepal',
        notes: '',
        docsUrl: '',
        credentialFields: [SmsProviderField(key: 'token', label: 'API token', required: true, secret: true)],
        configurationFields: [SmsProviderField(key: 'from', label: 'Sender ID', required: true, secret: false)],
      );
      const existing = ConfiguredSmsProvider(
        id: 'p1',
        providerType: 'sparrow_sms',
        displayName: 'Sparrow',
        enabled: true,
        priority: 10,
        available: true,
        configuration: {'from': 'ResQNet'},
        configuredCredentialFields: {'token'},
        credentialsReadable: true,
      );
      final requests = <Map<String, dynamic>>[];
      await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
      final service = SmsProviderAdminService(
        client: EmployeeApiClient(
          httpClient: FakeHttpClient((request) async {
            requests.add(Map<String, dynamic>.from(
              jsonDecode((request as http.Request).body) as Map,
            ));
            return jsonStreamedResponse(200, {
              'provider': {'id': 'p1', 'providerType': 'sparrow_sms', 'displayName': 'Sparrow'},
            });
          }),
        ),
      );

      await tester.pumpWidget(MaterialApp(
        home: SmsProviderFormScreen(type: type, existing: existing, service: service),
      ));

      final secret = tester.widget<EditableText>(
        find.descendant(of: find.byKey(const Key('secret-token')), matching: find.byType(EditableText)),
      );
      expect(secret.controller.text, isEmpty);
      expect(secret.obscureText, isTrue);
      expect(find.textContaining('leave blank to keep'), findsOneWidget);

      await tester.tap(find.byKey(const Key('save-provider')));
      // Wait (bounded) for the real async save, rather than a fixed sleep.
      await tester.runAsync(() async {
        for (var i = 0; i < 200 && requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(requests, hasLength(1));
      expect(requests.single.containsKey('credentials'), isFalse);
      expect(requests.single['configuration'], {'from': 'ResQNet'});
    });
  });
}
