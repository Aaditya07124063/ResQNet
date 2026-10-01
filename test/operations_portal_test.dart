import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:resqnet/core/employee/employee_api_client.dart';
import 'package:resqnet/core/employee/employee_session.dart';
import 'package:resqnet/core/employee/employee_token_storage.dart';
import 'package:resqnet/core/employee/incident_workflow.dart';
import 'package:resqnet/core/employee/operations_api.dart';
import 'package:resqnet/features/employee/employee_portal_screen.dart';
import 'package:resqnet/features/operations/incident_detail_page.dart';
import 'package:resqnet/features/operations/incident_map_page.dart';
import 'package:resqnet/features/operations/ops_common.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

const me = 'e1';
const other = 'e2';
const third = 'e3';
const incidentId = '55555555-5555-5555-5555-555555555555';

Map<String, dynamic> meJson(List<String> permissions, {String role = 'employee'}) => {
      'employee': {'id': me, 'email': 'ops@resqnet.co', 'displayName': 'Ops Lead', 'role': role},
      'permissions': [for (final p in permissions) {'permission': p}],
    };

Map<String, dynamic> incidentJson({
  String id = incidentId,
  String ops = 'reported',
  String civilian = 'active',
  String? assigned,
  String received = '2026-09-28T08:00:00.000Z',
}) =>
    {
      'id': id,
      'eventId': 'ev-$id',
      'category': 'medical',
      'eventSource': 'manual',
      'opsStatus': ops,
      'civilianState': civilian,
      'reporterStatus': 'open',
      'originVerificationState': 'not_applicable',
      'assignedEmployeeId': assigned,
      'approximateLatitude': 27.72,
      'approximateLongitude': 85.32,
      'receivedAt': received,
    };

Map<String, dynamic> detailJson({
  String ops = 'reported',
  String civilian = 'active',
  String? assigned,
  bool sensitive = false,
  List<Map<String, dynamic>> timeline = const [],
}) =>
    {
      ...incidentJson(ops: ops, civilian: civilian, assigned: assigned),
      'includesSensitiveDetails': sensitive,
      'message': sensitive ? 'Leg injury' : null,
      'latitude': sensitive ? 27.717245 : 27.72,
      'longitude': sensitive ? 85.323961 : 85.32,
      'locationAccuracyM': sensitive ? 12 : null,
      'reporter': {'displayName': 'Asha', 'phoneNumber': sensitive ? '+9779800000000' : null},
      'timeline': timeline,
    };

http.StreamedResponse ok(Map<String, dynamic> body) => jsonStreamedResponse(200, body);
http.StreamedResponse err(int status, String code, String message) => jsonStreamedResponse(status, {
      'error': {'code': code, 'message': message}
    });

typedef Routes = Future<http.StreamedResponse>? Function(http.BaseRequest request, String path);

class Harness {
  Harness(this.session, this.client);
  final EmployeeSession session;
  final FakeHttpClient client;

  List<http.BaseRequest> sent(String pathSuffix, {String method = 'GET'}) =>
      client.requests.where((r) => r.method == method && r.url.path.endsWith(pathSuffix)).toList();

  Map<String, dynamic> lastBody(String pathSuffix) =>
      jsonDecode((sent(pathSuffix, method: 'POST').last as http.Request).body) as Map<String, dynamic>;
}

Future<Harness> pumpPortal(
  WidgetTester tester, {
  required List<String> permissions,
  Routes? routes,
  Widget? home,
  Size size = const Size(1400, 1000),
  String role = 'employee',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await EmployeeTokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
  final fake = FakeHttpClient((request) async {
    final path = request.url.path.replaceFirst('/api/v1/employee', '');
    if (path == '/me') return ok(meJson(permissions, role: role));
    final routed = routes?.call(request, path);
    if (routed != null) return routed;
    if (path == '/incidents/summary') {
      return ok({
        'counts': {
          'generatedAt': '2026-09-28T08:30:00.000Z',
          'byResponderState': {'reported': 2, 'assigned': 1, 'resolved': 4},
          'openButCivilianSafe': 1,
          'openButCivilianCancelled': 0,
          'oldestUnacknowledgedAt': '2026-09-28T08:00:00.000Z',
        }
      });
    }
    if (path == '/incidents') return ok({'incidents': [incidentJson()], 'nextCursor': null});
    if (path == '/alerts') return ok({'alerts': []});
    return err(404, 'NOT_FOUND', 'No route');
  });
  final client = EmployeeApiClient(httpClient: fake);
  EmployeeApiClient.instance = client;
  final session = EmployeeSession(client: client);
  await tester.runAsync(session.restore);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<EmployeeSession>.value(value: session),
      Provider<OperationsApi>.value(value: OperationsApi(client: client)),
    ],
    child: MaterialApp(home: home ?? const EmployeePortalScreen()),
  ));
  await tester.pumpAndSettle();
  return Harness(session, fake);
}

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> confirmDialog(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, label)));
  await tester.pumpAndSettle();
}

void main() {
  late FakeSecureStorage storage;
  setUp(() => storage = FakeSecureStorage());
  tearDown(() {
    storage.dispose();
    EmployeeApiClient.instance = EmployeeApiClient();
  });

  group('workflow rules (UI side)', () {
    const monitor = IncidentActor(employeeId: me, canRespond: false, canAssign: false);
    const responder = IncidentActor(employeeId: me, canRespond: true, canAssign: false);
    const dispatcher = IncidentActor(employeeId: me, canRespond: true, canAssign: true);

    test('the transition table matches the backend state machine exactly', () {
      final source = File('backend/src/services/incidentStateMachine.ts').readAsStringSync();
      final block = source.substring(source.indexOf('RESPONDER_TRANSITIONS'));
      final table = <String, List<String>>{};
      for (final m in RegExp(r"^\s+(\w+): \[([^\]]*)\],", multiLine: true).allMatches(block)) {
        table[m[1]!] = RegExp(r"'(\w+)'").allMatches(m[2]!).map((x) => x[1]!).toList();
        if (table.length == responderStates.length) break;
      }
      expect(table, responderTransitions);
    });

    test('monitoring alone offers no actions', () {
      for (final s in responderStates) {
        expect(availableTransitions(opsStatus: s, assignedEmployeeId: me, actor: monitor), isEmpty);
      }
      expect(canAddNote(monitor), isFalse);
    });

    test('a responder can acknowledge, and progress only their own assignment', () {
      expect(availableTransitions(opsStatus: 'reported', assignedEmployeeId: null, actor: responder), ['acknowledged']);
      expect(availableTransitions(opsStatus: 'assigned', assignedEmployeeId: other, actor: responder), isEmpty);
      expect(availableTransitions(opsStatus: 'assigned', assignedEmployeeId: me, actor: responder), ['en_route']);
      expect(availableTransitions(opsStatus: 'arrived', assignedEmployeeId: me, actor: responder), ['assisting', 'resolved']);
    });

    test('a dispatcher can assign, reassign, stand down and record for others', () {
      expect(availableTransitions(opsStatus: 'reported', assignedEmployeeId: null, actor: dispatcher), ['acknowledged', 'assigned', 'stood_down']);
      expect(availableTransitions(opsStatus: 'en_route', assignedEmployeeId: other, actor: dispatcher), ['arrived', 'assigned', 'stood_down']);
      expect(availableTransitions(opsStatus: 'arrived', assignedEmployeeId: other, actor: dispatcher), ['assisting', 'resolved']);
    });

    test('resolved and stood down offer nothing', () {
      for (final s in terminalResponderStates) {
        expect(availableTransitions(opsStatus: s, assignedEmployeeId: me, actor: dispatcher), isEmpty);
      }
    });

    test('timeline text distinguishes the reporter from responders, and reassignment from assignment', () {
      TimelineEntry entry(Map<String, dynamic> j) => TimelineEntry.fromJson({'at': '2026-09-28T08:00:00Z', ...j});
      String? names(String? id) => {me: 'You', other: 'Medic'}[id];
      expect(describeTimelineEntry(entry({'action': 'civilian_state', 'newState': 'safe'})), 'Reporter marked themselves safe');
      expect(describeTimelineEntry(entry({'action': 'civilian_state', 'newState': 'cancelled'})), 'Reporter cancelled the SOS');
      expect(
        describeTimelineEntry(entry({'action': 'assigned', 'employeeId': me, 'assignedEmployeeId': other, 'previousState': 'reported'}), nameOf: names),
        'You assigned the incident to Medic',
      );
      expect(
        describeTimelineEntry(entry({'action': 'assigned', 'employeeId': me, 'assignedEmployeeId': other, 'previousState': 'en_route'}), nameOf: names),
        'You reassigned the incident to Medic',
      );
    });

    test('map clustering merges nearby incidents when zoomed out and separates them when zoomed in', () {
      final points = [const LatLng(27.70, 85.30), const LatLng(27.71, 85.31), const LatLng(28.20, 83.98)];
      expect(clusterByGrid<LatLng>(points, (p) => p, 7).length, 2);
      expect(clusterByGrid<LatLng>(points, (p) => p, 15).length, 3);
    });

    test('ages are compact and never negative', () {
      final now = DateTime(2026, 9, 28, 12);
      expect(formatAge(now.subtract(const Duration(seconds: 30)), now: now), '30 s');
      expect(formatAge(now.subtract(const Duration(minutes: 12)), now: now), '12 min');
      expect(formatAge(now.subtract(const Duration(hours: 5)), now: now), '5 h');
      expect(formatAge(now.add(const Duration(minutes: 1)), now: now), '0 s');
    });
  });

  group('OperationsApi', () {
    test('queue requests carry scope, filters, page size and cursor; the cursor is returned', () async {
      final fake = FakeHttpClient((_) async => ok({'incidents': [incidentJson()], 'nextCursor': 'next-1'}));
      final page = await OperationsApi(client: EmployeeApiClient(httpClient: fake))
          .listIncidents(scope: 'all', opsStatus: 'en_route', civilianState: 'safe', assignee: 'unassigned', cursor: 'c0', limit: 25);
      expect(page.nextCursor, 'next-1');
      expect(page.incidents.single.latitude, 27.72);
      expect(fake.requests.single.url.queryParameters, {
        'scope': 'all',
        'opsStatus': 'en_route',
        'civilianState': 'safe',
        'assignee': 'unassigned',
        'cursor': 'c0',
        'limit': '25',
      });
    });

    test('a responder update posts only the fields that apply', () async {
      final fake = FakeHttpClient((_) async => jsonStreamedResponse(201, {'opsStatus': 'assigned'}));
      final api = OperationsApi(client: EmployeeApiClient(httpClient: fake));
      expect(await api.recordUpdate(incidentId, 'assigned', assignedEmployeeId: other), 'assigned');
      expect(jsonDecode((fake.requests.single as http.Request).body), {'action': 'assigned', 'assignedEmployeeId': other});
      expect(fake.requests.single.url.path, '/api/v1/employee/incidents/$incidentId/updates');
    });

    test('audit log paging uses the id marker', () async {
      final fake = FakeHttpClient((_) async => ok({'entries': [], 'nextBefore': null}));
      await OperationsApi(client: EmployeeApiClient(httpClient: fake)).auditLogs(resourceType: 'sos_event', before: '41');
      expect(fake.requests.single.url.queryParameters, {'resourceType': 'sos_event', 'before': '41', 'limit': '50'});
    });
  });

  group('portal navigation and permissions', () {
    testWidgets('SOS_MONITOR sees the operations sections but not responders, SMS or audit', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR']);
      for (final id in ['dashboard', 'incidents', 'map', 'alerts', 'sources', 'account']) {
        expect(find.byKey(Key('ops-nav-$id')), findsOneWidget, reason: id);
      }
      for (final id in ['responders', 'sms', 'audit']) {
        expect(find.byKey(Key('ops-nav-$id')), findsNothing, reason: id);
      }
    });

    testWidgets('an employee without permissions only sees their account, with an explanation', (tester) async {
      await pumpPortal(tester, permissions: []);
      expect(find.byKey(const Key('ops-no-permissions')), findsOneWidget);
      expect(find.byKey(const Key('ops-nav-incidents')), findsNothing);
      expect(find.text('Ops Lead'), findsWidgets);
    });

    testWidgets('super_admin sees every section', (tester) async {
      await pumpPortal(tester, permissions: [], role: 'super_admin');
      for (final id in ['dashboard', 'incidents', 'map', 'alerts', 'sources', 'responders', 'sms', 'audit', 'account']) {
        expect(find.byKey(Key('ops-nav-$id')), findsOneWidget, reason: id);
      }
    });

    testWidgets('narrow screens use a navigation drawer', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], size: const Size(700, 1000));
      expect(find.byKey(const Key('ops-nav-rail')), findsNothing);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ops-nav-drawer')), findsOneWidget);
    });

    testWidgets('an expired session returns to sign-in and says why', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/auth/refresh') return Future.value(err(401, 'UNAUTHORIZED', 'revoked'));
        if (path == '/incidents') return Future.value(err(401, 'UNAUTHORIZED', 'expired'));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      expect(find.text('Staff sign-in'), findsOneWidget);
      expect(find.byKey(const Key('employee-signed-out-reason')), findsOneWidget);
      expect(await EmployeeTokenStorage.instance.readRefreshToken(), isNull);
      expect(h.session.isSignedIn, isFalse);
    });
  });

  group('dashboard', () {
    testWidgets('shows server counts with their timestamp as system records, and opens a filtered queue', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR']);
      expect(find.byKey(const Key('dashboard-disclaimer')), findsOneWidget);
      expect(find.textContaining('not real-world statistics'), findsOneWidget);
      expect(find.byKey(const Key('dashboard-oldest-unacknowledged')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-no-alerts')), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('dashboard-count-Unacknowledged')));
      final queued = h.sent('/incidents');
      expect(queued.last.url.queryParameters['opsStatus'], 'reported');
      expect(find.byKey(const Key('queue-table')), findsOneWidget);
    });
  });

  group('incident queue', () {
    testWidgets('loads pages with the cursor and appends them', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path != '/incidents') return null;
        return Future.value(r.url.queryParameters['cursor'] == 'c1'
            ? ok({'incidents': [incidentJson(id: '66666666-6666-6666-6666-666666666666', ops: 'assigned', assigned: other)], 'nextCursor': null})
            : ok({'incidents': [incidentJson()], 'nextCursor': 'c1'}));
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      expect(find.text('55555555'), findsOneWidget); // short incident id in the table
      await tapAndSettle(tester, find.byKey(const Key('queue-load-more')));
      expect(h.sent('/incidents').last.url.queryParameters['cursor'], 'c1');
      expect(find.text('Unacknowledged'), findsWidgets);
      expect(find.text('Assigned'), findsWidgets);
      expect(find.textContaining('end of list'), findsOneWidget);
      expect(find.byKey(const Key('ops-refreshed-stamp')), findsOneWidget);
      // Approximate position only — the queue never has the exact one.
      expect(find.text('≈ 27.72, 85.32'), findsNWidgets(2));
    });

    testWidgets('an empty queue says so honestly', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/incidents') return Future.value(ok({'incidents': [], 'nextCursor': null}));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      expect(find.text('No open incidents'), findsOneWidget);
    });

    testWidgets('a permission refusal shows "Not permitted"', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/incidents') return Future.value(err(403, 'FORBIDDEN', 'Missing required permission: SOS_MONITOR'));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      expect(find.text('Not permitted'), findsOneWidget);
    });

    testWidgets('a network failure offers a retry', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/incidents') throw const SocketException('offline');
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      expect(find.textContaining('Could not reach the ResQNet server'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('incident detail', () {
    Widget detail() => const IncidentDetailPage(incidentId: incidentId);

    testWidgets('SOS_MONITOR alone: approximate location, contact and notes restricted, no actions', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') {
          return Future.value(ok({
            'incident': detailJson(timeline: [
              {'action': 'note', 'employeeId': other, 'actorRole': 'employee', 'note': null, 'noteHidden': true, 'at': '2026-09-28T08:05:00Z'},
            ])
          }));
        }
        return null;
      });
      expect(find.byKey(const Key('incident-view-only')), findsOneWidget);
      expect(find.byKey(const Key('incident-location-restricted')), findsOneWidget);
      expect(find.byKey(const Key('incident-contact-restricted')), findsOneWidget);
      expect(find.text('Restricted'), findsNWidgets(2));
      expect(find.text('Note text restricted (SOS_RESPOND)'), findsOneWidget);
      expect(find.textContaining('27.717245'), findsNothing);
      expect(find.byKey(const Key('incident-note')), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('reporter marked safe while assigned: banner, reporter entry, incident still actionable', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND'], home: detail(), size: const Size(1400, 2400), routes: (r, path) {
        if (path == '/incidents/$incidentId') {
          return Future.value(ok({
            'incident': detailJson(ops: 'assigned', civilian: 'safe', assigned: me, sensitive: true, timeline: [
              {'action': 'assigned', 'employeeId': other, 'assignedEmployeeId': me, 'previousState': 'reported', 'newState': 'assigned', 'at': '2026-09-28T08:01:00Z'},
              {'action': 'civilian_state', 'employeeId': null, 'previousState': 'active', 'newState': 'safe', 'at': '2026-09-28T08:02:00Z'},
            ])
          }));
        }
        return null;
      });
      expect(find.byKey(const Key('incident-civilian-banner')), findsOneWidget);
      expect(find.textContaining('stays open until a responder'), findsOneWidget);
      expect(find.text('Reporter marked themselves safe'), findsOneWidget);
      expect(find.textContaining('Reporter ·'), findsOneWidget);
      expect(find.text('27.717245, 85.323961'), findsOneWidget);
      expect(find.text('+9779800000000'), findsOneWidget);
      expect(find.byKey(const Key('incident-action-en_route')), findsOneWidget);
    });

    testWidgets('the assigned responder marks en route after confirming', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(ops: 'assigned', assigned: me, sensitive: true)}));
        if (path.endsWith('/updates')) return Future.value(jsonStreamedResponse(201, {'opsStatus': 'en_route'}));
        return null;
      });
      expect(find.byKey(const Key('incident-action-assigned')), findsNothing);
      expect(find.byKey(const Key('incident-action-stood_down')), findsNothing);
      await tapAndSettle(tester, find.byKey(const Key('incident-action-en_route')));
      await confirmDialog(tester, 'Mark en route');
      expect(h.lastBody('/updates'), {'action': 'en_route'});
    });

    testWidgets('someone else\'s assignment cannot be progressed by a plain responder', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(ops: 'en_route', assigned: other, sensitive: true)}));
        return null;
      });
      expect(find.byKey(const Key('incident-action-arrived')), findsNothing);
      expect(find.textContaining('recorded by the assigned responder'), findsOneWidget);
    });

    testWidgets('a dispatcher reassigns to an eligible responder, never the current one, after confirming', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND', 'SOS_ASSIGN'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(ops: 'en_route', assigned: other, sensitive: true)}));
        if (path == '/incidents/responders') {
          return Future.value(ok({
            'responders': [
              {'id': other, 'displayName': 'Medic', 'role': 'employee', 'openAssignments': 1},
              {'id': third, 'displayName': 'Driver', 'role': 'employee', 'openAssignments': 0},
            ]
          }));
        }
        if (path.endsWith('/updates')) return Future.value(jsonStreamedResponse(201, {'opsStatus': 'assigned'}));
        return null;
      });
      expect(find.text('Medic'), findsOneWidget); // current assignee, by name
      await tapAndSettle(tester, find.byKey(const Key('incident-action-assigned')));
      expect(find.byKey(const Key('assign-option-$other')), findsNothing);
      await tapAndSettle(tester, find.byKey(const Key('assign-option-$third')));
      await tapAndSettle(tester, find.byKey(const Key('assign-continue')));
      await confirmDialog(tester, 'Reassign');
      expect(h.lastBody('/updates'), {'action': 'assigned', 'assignedEmployeeId': third});
    });

    testWidgets('standing down needs a reason', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND', 'SOS_ASSIGN'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(ops: 'acknowledged', civilian: 'cancelled', sensitive: true)}));
        if (path == '/incidents/responders') return Future.value(ok({'responders': []}));
        if (path.endsWith('/updates')) return Future.value(jsonStreamedResponse(201, {'opsStatus': 'stood_down'}));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('incident-action-stood_down')));
      final confirm = find.byKey(const Key('stand-down-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('stand-down-reason')), 'Reporter cancelled; confirmed by phone');
      await tester.pumpAndSettle();
      await tapAndSettle(tester, confirm);
      expect(h.lastBody('/updates'), {'action': 'stood_down', 'note': 'Reporter cancelled; confirmed by phone'});
    });

    testWidgets('a rejected transition (409) is explained and the incident reloaded', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(sensitive: true)}));
        if (path.endsWith('/updates')) {
          return Future.value(err(409, 'INVALID_TRANSITION', 'The incident is already acknowledged'));
        }
        return null;
      });
      final loadsBefore = h.sent('/incidents/$incidentId').length;
      await tapAndSettle(tester, find.byKey(const Key('incident-action-acknowledged')));
      await confirmDialog(tester, 'Acknowledge');
      expect(find.textContaining('The incident is already acknowledged'), findsOneWidget);
      expect(h.sent('/incidents/$incidentId').length, loadsBefore + 1);
    });

    testWidgets('notes are sent trimmed and only by responders', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND'], home: detail(), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(ops: 'resolved', assigned: me, sensitive: true)}));
        if (path.endsWith('/updates')) return Future.value(jsonStreamedResponse(201, {'opsStatus': 'resolved'}));
        return null;
      });
      expect(find.textContaining('Only notes can be added'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('incident-note')), '  Follow-up call made  ');
      await tapAndSettle(tester, find.byKey(const Key('incident-add-note')));
      expect(h.lastBody('/updates'), {'action': 'note', 'note': 'Follow-up call made'});
    });
  });

  group('alerts and sources', () {
    Map<String, dynamic> alertJson({String type = 'resqnet_system', String? retrievedAt, String? url}) => {
          'id': 'a1',
          'sourceType': type,
          'sourceName': type == 'international_public' ? 'Public Quake Catalogue' : 'ResQNet Operations',
          'sourceUrl': url,
          'retrievedAt': retrievedAt,
          'category': 'earthquake',
          'severity': 'info',
          'status': 'active',
          'title': 'M4.8 earthquake',
          'body': 'Felt in Gorkha',
          'area': {'latitude': 28.2, 'longitude': 84.7, 'radiusKm': 50},
          'issuedAt': '2026-09-28T07:00:00Z',
          'expiresAt': null,
          'updatedAt': '2026-09-28T07:00:00Z',
        };

    testWidgets('a monitor sees provenance but cannot publish or edit', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/alerts') {
          return Future.value(ok({
            'alerts': [alertJson(type: 'international_public', retrievedAt: '2026-09-28T07:05:00Z', url: 'https://example.org/q-1')]
          }));
        }
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-alerts')));
      expect(find.text('PUBLIC INTERNATIONAL SOURCE'), findsOneWidget);
      expect(find.textContaining('Fetched from an external feed'), findsOneWidget);
      expect(find.text('https://example.org/q-1'), findsOneWidget);
      expect(find.byKey(const Key('alerts-new')), findsNothing);
      expect(find.byKey(const Key('alert-resolve-a1')), findsNothing);
      expect(find.textContaining('View only'), findsOneWidget);
    });

    testWidgets('a ResQNet-notice publisher can only choose the RESQNET label', (tester) async {
      await pumpPortal(tester, permissions: ['SYSTEM_ALERT_PUBLISH'], routes: (r, path) {
        if (path == '/alerts') return Future.value(ok({'alerts': [alertJson()]}));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-alerts')));
      expect(find.byKey(const Key('ops-nav-incidents')), findsNothing);
      expect(find.byKey(const Key('alert-resolve-a1')), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const Key('alerts-new')));
      await tapAndSettle(tester, find.byKey(const Key('alert-source-type')));
      expect(find.text('RESQNET'), findsWidgets);
      expect(find.text('OFFICIAL'), findsNothing);
      expect(find.text('VERIFIED PARTNER'), findsNothing);
    });

    testWidgets('disaster sources are honestly shown as not connected', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/alerts/sources') return Future.value(ok({'sources': {'registered': [], 'scheduledIngestion': false, 'observed': []}}));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-sources')));
      expect(find.byKey(const Key('sources-none')), findsOneWidget);
      expect(find.textContaining('No external disaster source is connected'), findsOneWidget);
      expect(find.byKey(const Key('sources-observed-none')), findsOneWidget);
    });
  });

  group('audit log', () {
    testWidgets('lists entries with actor, role and result, and pages by id', (tester) async {
      Map<String, dynamic> entry(String id) => {
            'id': id,
            'at': '2026-09-28T08:00:00Z',
            'actor': {'kind': 'employee', 'id': other, 'displayName': 'Medic', 'role': 'employee'},
            'action': 'incident.en_route',
            'resourceType': 'sos_event',
            'resourceId': incidentId,
            'outcome': 'success',
            'metadata': {'previousState': 'assigned', 'newState': 'en_route', 'refreshToken': '[redacted]'},
          };
      final h = await pumpPortal(tester, permissions: ['AUDIT_LOG_VIEW'], routes: (r, path) {
        if (path != '/audit-logs') return null;
        return Future.value(r.url.queryParameters['before'] == '41'
            ? ok({'entries': [entry('40')], 'nextBefore': null})
            : ok({'entries': [entry('42'), entry('41')], 'nextBefore': '41'}));
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-audit')));
      expect(find.text('incident.en_route · success'), findsNWidgets(2));
      expect(find.textContaining('Medic (employee)'), findsNWidgets(2));
      await tapAndSettle(tester, find.byKey(const Key('audit-load-more')));
      expect(h.sent('/audit-logs').last.url.queryParameters['before'], '41');
      expect(find.text('incident.en_route · success'), findsNWidgets(3));
      expect(find.textContaining('end of log'), findsOneWidget);
    });
  });

  group('accessibility guidelines', () {
    Future<void> checkGuidelines(WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    }

    testWidgets('dashboard', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR']);
      await checkGuidelines(tester);
    });

    testWidgets('incident queue', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR']);
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      await checkGuidelines(tester);
    });

    testWidgets('incident detail with actions', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND', 'SOS_ASSIGN'], home: const IncidentDetailPage(incidentId: incidentId), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': detailJson(sensitive: true)}));
        if (path == '/incidents/responders') return Future.value(ok({'responders': []}));
        return null;
      });
      await checkGuidelines(tester);
    });
  });

  group('record retention in the portal', () {
    Map<String, dynamic> removedDetail() => {
          ...detailJson(ops: 'resolved', sensitive: true),
          'sensitiveRemoved': true,
          'includesSensitiveDetails': false,
          'message': null,
          'latitude': null,
          'longitude': null,
          'reporter': null,
          'lifecycle': {
            'closedAt': '2025-01-01T00:00:00Z',
            'sensitiveRedactedAt': '2025-04-01T00:00:00Z',
            'deidentifiedAt': '2027-01-01T00:00:00Z',
            'retentionHold': null,
          },
          'timeline': [
            {'action': 'note', 'employeeId': other, 'note': null, 'noteHidden': false, 'noteRemoved': true, 'at': '2025-01-01T00:00:00Z'},
          ],
        };

    testWidgets('removed details are labelled as removed, not restricted or missing', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR', 'SOS_RESPOND'], size: const Size(1400, 2600), home: const IncidentDetailPage(incidentId: incidentId), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': removedDetail()}));
        return null;
      });
      expect(find.byKey(const Key('incident-location-removed')), findsOneWidget);
      expect(find.text('Removed under the retention policy'), findsNWidgets(2));
      expect(find.text('Note text removed under the retention policy'), findsOneWidget);
      expect(find.text('Link to the account removed under the retention policy'), findsOneWidget);
      expect(find.text('Restricted'), findsNothing);
      expect(find.textContaining('did not report a location'), findsNothing);
      expect(find.byKey(const Key('incident-retention-hold')), findsNothing); // no permission, and already de-identified
    });

    testWidgets('placing a hold needs RETENTION_HOLD_MANAGE and a reason', (tester) async {
      final h = await pumpPortal(tester, permissions: ['SOS_MONITOR', 'RETENTION_HOLD_MANAGE'], size: const Size(1400, 2600), home: const IncidentDetailPage(incidentId: incidentId), routes: (r, path) {
        if (path == '/incidents/$incidentId') return Future.value(ok({'incident': {...detailJson(ops: 'resolved'), 'lifecycle': {'closedAt': '2026-09-01T00:00:00Z'}}}));
        if (path.endsWith('/retention-hold')) return Future.value(ok({'retentionHold': true, 'sensitiveAlreadyRedacted': false}));
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('incident-retention-hold')));
      final confirm = find.byKey(const Key('hold-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('hold-reason')), 'Complaint under review');
      await tester.pumpAndSettle();
      await tapAndSettle(tester, confirm);
      expect(h.lastBody('/retention-hold'), {'hold': true, 'reason': 'Complaint under review'});
    });

    testWidgets('the queue shows removed locations as removed', (tester) async {
      await pumpPortal(tester, permissions: ['SOS_MONITOR'], routes: (r, path) {
        if (path == '/incidents') {
          return Future.value(ok({
            'incidents': [
              {...incidentJson(ops: 'resolved'), 'approximateLatitude': null, 'approximateLongitude': null, 'sensitiveRemoved': true}
            ],
            'nextCursor': null,
          }));
        }
        return null;
      });
      await tapAndSettle(tester, find.byKey(const Key('ops-nav-incidents')));
      expect(find.text('Removed (retention)'), findsOneWidget);
    });
  });
}
