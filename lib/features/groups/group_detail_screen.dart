import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/network/api_exception.dart';
import '../../core/services/group_service.dart';
import '../../core/services/trusted_contacts_service.dart';
import '../auth/auth_service.dart';
import '../communication/chat_screen.dart';

/// Members of a group and its chat. Members can be added only from the
/// user's trusted contacts who use ResQNet (the backend enforces this).
class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  GroupSummary? _group;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final group = await context.read<GroupService>().detail(widget.groupId);
      if (mounted) setState(() => _group = group);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isNetworkError ? 'No internet connection.' : 'Could not load this group.');
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _describe(ApiException e) => e.isNetworkError ? 'No internet connection.' : e.message;

  Future<void> _addMember() async {
    final group = _group!;
    final existing = group.members.map((m) => m.userId).toSet();
    final candidates = context
        .read<TrustedContactsService>()
        .contacts
        .where((c) => c.contactUserId != null && !existing.contains(c.contactUserId))
        .toList();
    if (candidates.isEmpty) {
      _snack('None of your trusted contacts use ResQNet yet, or they are already in this group.');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in candidates)
              ListTile(
                leading: const Icon(Icons.person_add),
                title: Text(c.name),
                subtitle: Text(c.relation),
                onTap: () => Navigator.pop(sheetContext, c.contactUserId),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await context.read<GroupService>().addMember(group.id, picked);
      await _load();
    } on ApiException catch (e) {
      _snack(_describe(e));
    }
  }

  Future<void> _remove(GroupMember member) async {
    try {
      await context.read<GroupService>().removeMember(_group!.id, member.userId);
      await _load();
    } on ApiException catch (e) {
      _snack(_describe(e));
    }
  }

  Future<void> _transferOwnership(String myId) async {
    final group = _group!;
    final others = group.members.where((m) => m.userId != myId).toList();
    final picked = await showModalBottomSheet<GroupMember>(
      context: context,
      backgroundColor: AppColors.surfaceDark,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Choose the new owner. You will stay in the group as an admin and can leave afterwards.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            for (final m in others)
              ListTile(
                leading: const Icon(Icons.manage_accounts),
                title: Text(m.displayName ?? 'ResQNet user', style: TextStyle(color: AppColors.textPrimary)),
                subtitle: Text(m.role, style: TextStyle(color: AppColors.textSecondary)),
                onTap: () => Navigator.pop(sheetContext, m),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await context.read<GroupService>().transferOwnership(group.id, picked.userId);
      await _load();
    } on ApiException catch (e) {
      _snack(_describe(e));
    }
  }

  Future<void> _leave() async {
    final myId = context.read<AuthService>().currentUser?.id;
    if (myId == null) return;
    final navigator = Navigator.of(context);
    try {
      await context.read<GroupService>().leave(_group!.id, myId);
      navigator.pop();
    } on ApiException catch (e) {
      _snack(_describe(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final myId = context.watch<AuthService>().currentUser?.id;
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text(group?.name ?? 'Group', style: TextStyle(color: AppColors.textPrimary)),
      ),
      body: group == null
          ? Center(
              child: _error != null
                  ? Text(_error!, style: TextStyle(color: AppColors.textSecondary))
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ElevatedButton.icon(
                  key: const Key('group-open-chat'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(conversationId: group.conversationId, otherParticipantName: group.name),
                    ),
                  ),
                  icon: const Icon(Icons.chat),
                  label: const Text('Open group chat'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text('${group.members.length} members',
                          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                    ),
                    if (group.canManageMembers)
                      TextButton.icon(onPressed: _addMember, icon: const Icon(Icons.person_add), label: const Text('Add')),
                  ],
                ),
                for (final m in group.members)
                  ListTile(
                    title: Text(m.displayName ?? 'ResQNet user', style: TextStyle(color: AppColors.textPrimary)),
                    subtitle: Text(m.role, style: TextStyle(color: AppColors.textSecondary)),
                    trailing: group.canManageMembers && m.role != 'owner' && m.userId != myId
                        ? IconButton(
                            tooltip: 'Remove from group',
                            icon: const Icon(Icons.person_remove),
                            onPressed: () => _remove(m),
                          )
                        : null,
                  ),
                const SizedBox(height: 16),
                if (group.myRole != 'owner')
                  OutlinedButton.icon(
                    onPressed: _leave,
                    icon: const Icon(Icons.logout),
                    label: const Text('Leave group'),
                  )
                else if (myId != null && group.members.length > 1)
                  OutlinedButton.icon(
                    key: const Key('group-transfer-owner'),
                    onPressed: () => _transferOwnership(myId),
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Transfer ownership'),
                  ),
              ],
            ),
    );
  }
}
