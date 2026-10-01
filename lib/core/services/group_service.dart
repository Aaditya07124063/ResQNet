import 'package:flutter/foundation.dart';
import '../network/api_client.dart';

const groupKinds = <String, String>{
  'family': 'Family',
  'trekking': 'Trekking group',
  'friends': 'Friends',
  'rescue_team': 'Rescue team',
  'organization': 'Organization',
  'emergency': 'Emergency incident',
  'general': 'Other',
};

class GroupMember {
  const GroupMember({required this.userId, required this.displayName, required this.role});

  final String userId;
  final String? displayName;
  final String role;

  factory GroupMember.fromJson(Map<String, dynamic> json) => GroupMember(
        userId: json['userId'] as String,
        displayName: json['displayName'] as String?,
        role: json['role'] as String? ?? 'member',
      );
}

class GroupSummary {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.kind,
    required this.conversationId,
    required this.myRole,
    required this.memberCount,
    this.description,
    this.members = const [],
  });

  final String id;
  final String name;
  final String? description;
  final String kind;

  /// The group's chat — use the normal conversation/message APIs with it.
  final String conversationId;
  final String myRole;
  final int memberCount;
  final List<GroupMember> members;

  bool get canManageMembers => myRole == 'owner' || myRole == 'admin';

  factory GroupSummary.fromJson(Map<String, dynamic> json) => GroupSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        kind: json['kind'] as String? ?? 'general',
        conversationId: json['conversationId'] as String,
        myRole: json['myRole'] as String? ?? 'member',
        memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
        members: ((json['members'] as List?) ?? const [])
            .map((m) => GroupMember.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

/// Group membership against `/api/v1/groups`. Group chat itself goes
/// through [CommunicationService] with the group's conversation id, so
/// messages get the same offline outbox and retry as 1:1 chat.
class GroupService extends ChangeNotifier {
  GroupService({ApiClient? client}) : _client = client;

  final ApiClient? _client;
  ApiClient get _api => _client ?? ApiClient.instance;

  List<GroupSummary> _groups = const [];
  List<GroupSummary> get groups => _groups;

  Future<void> load() async {
    final result = await _api.get('/groups');
    _groups = ((result['groups'] as List?) ?? const [])
        .map((g) => GroupSummary.fromJson(g as Map<String, dynamic>))
        .toList();
    notifyListeners();
  }

  Future<GroupSummary> create({required String name, required String kind, String? description}) async {
    final result = await _api.post('/groups', auth: true, body: {
      'name': name,
      'kind': kind,
      if (description != null && description.trim().isNotEmpty) 'description': description.trim(),
    });
    final group = GroupSummary.fromJson(result['group'] as Map<String, dynamic>);
    _groups = [group, ..._groups];
    notifyListeners();
    return group;
  }

  Future<GroupSummary> detail(String groupId) async {
    final result = await _api.get('/groups/$groupId');
    return GroupSummary.fromJson(result['group'] as Map<String, dynamic>);
  }

  Future<void> addMember(String groupId, String userId) =>
      _api.postNoContent('/groups/$groupId/members', body: {'userId': userId}, auth: true);

  Future<void> removeMember(String groupId, String userId) => _api.delete('/groups/$groupId/members/$userId');

  Future<void> setRole(String groupId, String userId, String role) =>
      _api.patch('/groups/$groupId/members/$userId', body: {'role': role});

  /// Hands the group to another member; the caller becomes an admin and
  /// can then leave.
  Future<void> transferOwnership(String groupId, String newOwnerUserId) =>
      _api.postNoContent('/groups/$groupId/owner', body: {'userId': newOwnerUserId}, auth: true);

  Future<void> leave(String groupId, String myUserId) async {
    await removeMember(groupId, myUserId);
    _groups = _groups.where((g) => g.id != groupId).toList();
    notifyListeners();
  }
}
