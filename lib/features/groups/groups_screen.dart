import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/network/api_exception.dart';
import '../../core/services/group_service.dart';
import 'group_detail_screen.dart';

/// The user's groups (family, trekking party, rescue team, …).
class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await context.read<GroupService>().load();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.isNetworkError
            ? 'No internet connection. Groups need the ResQNet server; emergency SOS still works offline.'
            : e.isUnauthorized
                ? 'Sign in to use groups.'
                : 'Could not load your groups.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final created = await showDialog<GroupSummary>(context: context, builder: (_) => const _CreateGroupDialog());
    if (created != null && mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => GroupDetailScreen(groupId: created.id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = context.watch<GroupService>().groups;
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Groups', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create-group'),
        onPressed: _create,
        icon: const Icon(Icons.group_add),
        label: const Text('New group'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading && groups.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null && groups.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
                    ),
                  ])
                : groups.isEmpty
                    ? ListView(children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No groups yet. Create one for your family, trekking party, or team.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      ])
                    : ListView.builder(
                        itemCount: groups.length,
                        itemBuilder: (context, i) {
                          final g = groups[i];
                          return ListTile(
                            leading: const Icon(Icons.groups),
                            title: Text(g.name, style: TextStyle(color: AppColors.textPrimary)),
                            subtitle: Text(
                              '${groupKinds[g.kind] ?? g.kind} · ${g.memberCount} member${g.memberCount == 1 ? '' : 's'}',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => GroupDetailScreen(groupId: g.id)),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog();

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final _name = TextEditingController();
  String _kind = 'family';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a group name');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final group = await context.read<GroupService>().create(name: _name.text.trim(), kind: _kind);
      if (mounted) Navigator.pop(context, group);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.isNetworkError ? 'No internet connection.' : 'Could not create the group.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New group'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('group-name'),
            controller: _name,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Group name'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final entry in groupKinds.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (v) => setState(() => _kind = v ?? 'general'),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          key: const Key('group-create-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
