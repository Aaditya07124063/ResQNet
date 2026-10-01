import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:resqnet/core/models/conversation.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/group_service.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

Map<String, dynamic> groupJson({String role = 'owner', List<Map<String, dynamic>> members = const []}) => {
      'id': 'g1',
      'name': 'Annapurna trek',
      'description': null,
      'kind': 'trekking',
      'conversationId': 'conv-g1',
      'myRole': role,
      'memberCount': members.isEmpty ? 1 : members.length,
      'createdAt': '2026-09-27T00:00:00.000Z',
      'members': members,
    };

void main() {
  late FakeSecureStorage secureStorage;
  late List<http.Request> requests;

  setUp(() async {
    secureStorage = FakeSecureStorage();
    requests = [];
    await TokenStorage.instance.save(accessToken: 'access', refreshToken: 'refresh');
  });

  tearDown(() => secureStorage.dispose());

  GroupService service(Future<http.StreamedResponse> Function(http.Request r) respond) => GroupService(
        client: ApiClient(httpClient: FakeHttpClient((r) async {
          requests.add(r as http.Request);
          return respond(r);
        })),
      );

  test('create posts name and kind and adds the group to the list', () async {
    final groups = service((_) async => jsonStreamedResponse(201, {'group': groupJson()}));
    final group = await groups.create(name: 'Annapurna trek', kind: 'trekking');

    expect(requests.single.url.path, '/api/v1/groups');
    expect(jsonDecode(requests.single.body), {'name': 'Annapurna trek', 'kind': 'trekking'});
    expect(requests.single.headers['Authorization'], 'Bearer access');
    expect(group.conversationId, 'conv-g1');
    expect(groups.groups.single.id, 'g1');
  });

  test('detail parses members and role permissions', () async {
    final groups = service((_) async => jsonStreamedResponse(200, {
          'group': groupJson(role: 'member', members: [
            {'userId': 'u1', 'displayName': 'Owner', 'role': 'owner'},
            {'userId': 'u2', 'displayName': 'Me', 'role': 'member'},
          ]),
        }));
    final group = await groups.detail('g1');
    expect(group.members.map((m) => m.role), ['owner', 'member']);
    expect(group.canManageMembers, isFalse);
  });

  test('membership calls hit the documented routes', () async {
    final groups = service((r) async => r.method == 'PATCH' ? jsonStreamedResponse(200, {}) : emptyStreamedResponse(204));
    await groups.addMember('g1', 'u2');
    await groups.setRole('g1', 'u2', 'admin');
    await groups.removeMember('g1', 'u2');
    await groups.transferOwnership('g1', 'u2');

    expect(requests.map((r) => '${r.method} ${r.url.path}'), [
      'POST /api/v1/groups/g1/members',
      'PATCH /api/v1/groups/g1/members/u2',
      'DELETE /api/v1/groups/g1/members/u2',
      'POST /api/v1/groups/g1/owner',
    ]);
    expect(jsonDecode(requests.last.body), {'userId': 'u2'});
    expect(jsonDecode(requests.first.body), {'userId': 'u2'});
  });

  test('leaving removes yourself and drops the group locally', () async {
    final groups = service((r) async => r.method == 'POST'
        ? jsonStreamedResponse(201, {'group': groupJson(role: 'member')})
        : emptyStreamedResponse(204));
    await groups.create(name: 'x', kind: 'family');
    await groups.leave('g1', 'me');
    expect(requests.last.url.path, '/api/v1/groups/g1/members/me');
    expect(groups.groups, isEmpty);
  });

  test('a group conversation is titled with the group name', () {
    final summary = ConversationSummary.fromJson({
      'id': 'conv-g1',
      'type': 'group',
      'otherParticipant': null,
      'group': {'id': 'g1', 'name': 'Annapurna trek', 'kind': 'trekking'},
      'lastMessage': null,
      'unreadCount': 0,
      'updatedAt': '2026-09-27T00:00:00.000Z',
    });
    expect(summary.isGroup, isTrue);
    expect(summary.title, 'Annapurna trek');
  });
}
