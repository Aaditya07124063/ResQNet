import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/operations_api.dart';
import 'ops_common.dart';

/// Loads one value and renders loading / error / data consistently.
class _Loader<T> extends StatefulWidget {
  const _Loader({super.key, required this.load, required this.builder, required this.title});
  final Future<T> Function(OperationsApi api) load;
  final Widget Function(BuildContext context, T data) builder;
  final String title;

  @override
  State<_Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<_Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;
  DateTime? _refreshedAt;

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
      final data = await widget.load(context.read<OperationsApi>());
      if (!mounted) return;
      setState(() {
        _data = data;
        _refreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpsPageHeader(
          title: widget.title,
          subtitle: RefreshedStamp(refreshedAt: _refreshedAt),
          actions: [
            FilledButton.tonalIcon(
                onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Refresh'))
          ],
        ),
        Expanded(
          child: data == null
              ? (_loading
                  ? const Center(child: CircularProgressIndicator())
                  : ErrorPanel(error: _error ?? 'Unknown', onRetry: _load))
              : widget.builder(context, data),
        ),
      ],
    );
  }
}

class DisasterSourcesPage extends StatelessWidget {
  const DisasterSourcesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _Loader<DisasterSourceStatus>(
      title: 'Disaster sources',
      load: (api) => api.disasterSources(),
      builder: (context, status) => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          OpsCard(
            title: 'Connected sources',
            child: status.registered.isEmpty
                ? Text(
                    'No external disaster source is connected. No feed is verified for use yet, '
                    'and nothing fetches alerts on a schedule${status.scheduledIngestion ? '' : ' (ingestion is not scheduled)'}. '
                    'See docs/DISASTER_SOURCES.md.',
                    key: const Key('sources-none'),
                    style: TextStyle(color: OpsColors.text),
                  )
                : Column(children: [
                    for (final s in status.registered)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${s['sourceName']}', style: TextStyle(color: OpsColors.text)),
                        subtitle: Text(
                          '${s['homepageUrl'] ?? 'No homepage recorded'} · terms: ${(s['terms'] as Map?)?['status'] ?? 'unknown'}'
                          '${status.scheduledIngestion ? '' : ' · not fetched on a schedule'}',
                          style: TextStyle(color: OpsColors.textMuted),
                        ),
                        trailing: SourceTypeChip('${s['sourceType']}'),
                      ),
                  ]),
          ),
          OpsCard(
            title: 'Sources seen in stored alerts',
            child: status.observed.isEmpty
                ? Text('No alert in the database came from an external feed.',
                    key: const Key('sources-observed-none'), style: TextStyle(color: OpsColors.textMuted))
                : Column(children: [
                    for (final o in status.observed)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${o['sourceName']}', style: TextStyle(color: OpsColors.text)),
                        subtitle: Text(
                          'Last retrieved ${formatTimestamp(DateTime.tryParse('${o['lastRetrievedAt']}'))} · '
                          '${o['activeAlerts']} active of ${o['totalAlerts']} stored',
                          style: TextStyle(color: OpsColors.textMuted),
                        ),
                        trailing: SourceTypeChip('${o['sourceType']}'),
                      ),
                  ]),
          ),
        ],
      ),
    );
  }
}

class RespondersPage extends StatelessWidget {
  const RespondersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _Loader<List<EligibleResponder>>(
      title: 'Responders',
      load: (api) => api.responders(),
      builder: (context, responders) => responders.isEmpty
          ? const MessagePanel(
              icon: Icons.group_off_outlined,
              title: 'No eligible responders',
              message: 'No active employee holds SOS_RESPOND.')
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                      'Active employees who can be assigned to incidents (SOS_RESPOND). Contact details are managed in employee administration.',
                      style: TextStyle(color: OpsColors.textMuted)),
                ),
                for (final r in responders)
                  OpsCard(
                    child: Row(children: [
                      Icon(Icons.badge_outlined, color: OpsColors.textMuted),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(r.displayName,
                              style: TextStyle(color: OpsColors.text, fontWeight: FontWeight.w600))),
                      Text('${r.role.replaceAll('_', ' ')} · ${r.openAssignments} open assignment(s)',
                          style: TextStyle(color: OpsColors.textMuted)),
                    ]),
                  ),
              ],
            ),
    );
  }
}

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<EmployeeSession>();
    final employee = session.employee;
    final permissions = session.permissions.toList()..sort();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const OpsPageHeader(title: 'Account'),
        OpsCard(
          title: 'Signed in',
          child: Column(children: [
            FieldRow('Name', employee?.displayName),
            FieldRow('Email', employee?.email),
            FieldRow('Role', employee?.role.replaceAll('_', ' ')),
          ]),
        ),
        OpsCard(
          title: 'Permissions',
          child: employee?.isSuperAdmin == true
              ? Text('Super admin: every permission.', style: TextStyle(color: OpsColors.text))
              : permissions.isEmpty
                  ? Text('No permissions granted. Ask an administrator.', style: TextStyle(color: OpsColors.textMuted))
                  : Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final p in permissions) Chip(label: Text(p)),
                    ]),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('account-sign-out'),
              onPressed: session.busy ? null : session.logout,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ),
        ),
      ],
    );
  }
}

class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key});

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  static const _resourceTypes = ['sos_event', 'emergency_alert', 'sms_provider', 'employee', 'group', 'user'];
  final _actionPrefix = TextEditingController();
  final _resourceId = TextEditingController();
  String? _resourceType;
  String? _outcome;
  final List<AuditEntry> _entries = [];
  String? _nextBefore;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  DateTime? _refreshedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _actionPrefix.dispose();
    _resourceId.dispose();
    super.dispose();
  }

  Future<AuditPage> _fetch({String? before}) => context.read<OperationsApi>().auditLogs(
        resourceType: _resourceType,
        resourceId: _resourceId.text.trim(),
        actionPrefix: _actionPrefix.text.trim(),
        outcome: _outcome,
        before: before,
      );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetch();
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(page.entries);
        _nextBefore = page.nextBefore;
        _refreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final before = _nextBefore;
    if (before == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetch(before: before);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _nextBefore = page.nextBefore;
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeApiError(e))));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _actor(AuditEntry e) => switch (e.actorKind) {
        'employee' => '${e.actorName ?? 'Former employee'} (${(e.actorRole ?? 'employee').replaceAll('_', ' ')})',
        'user' => 'App user ${shortId(e.actorId ?? '')}',
        _ => 'System',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpsPageHeader(
          title: 'Audit log',
          subtitle: RefreshedStamp(refreshedAt: _refreshedAt),
          actions: [
            FilledButton.tonalIcon(
                onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Refresh'))
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String?>(
              key: const Key('audit-filter-resource'),
              value: _resourceType,
              hint: const Text('Any resource'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Any resource')),
                for (final r in _resourceTypes) DropdownMenuItem(value: r, child: Text(r)),
              ],
              onChanged: (v) {
                setState(() => _resourceType = v);
                _load();
              },
            ),
            DropdownButton<String?>(
              value: _outcome,
              hint: const Text('Any result'),
              items: const [
                DropdownMenuItem(value: null, child: Text('Any result')),
                DropdownMenuItem(value: 'success', child: Text('Success')),
                DropdownMenuItem(value: 'denied', child: Text('Denied')),
                DropdownMenuItem(value: 'error', child: Text('Error')),
              ],
              onChanged: (v) {
                setState(() => _outcome = v);
                _load();
              },
            ),
            SizedBox(
              width: 200,
              child: TextField(
                controller: _actionPrefix,
                decoration:
                    const InputDecoration(labelText: 'Action starts with', hintText: 'incident.', isDense: true),
                onSubmitted: (_) => _load(),
              ),
            ),
            SizedBox(
              width: 300,
              child: TextField(
                key: const Key('audit-filter-resource-id'),
                controller: _resourceId,
                decoration: const InputDecoration(labelText: 'Resource / incident ID', isDense: true),
                onSubmitted: (_) => _load(),
              ),
            ),
            OutlinedButton(onPressed: _load, child: const Text('Apply')),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading && _entries.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _entries.isEmpty) return ErrorPanel(error: _error!, onRetry: _load);
    if (_entries.isEmpty) return const MessagePanel(icon: Icons.history, title: 'No audit entries match');
    return SelectionArea(
        child: ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final e in _entries)
          ExpansionTile(
            key: ValueKey('audit-${e.id}'),
            leading: Icon(
              e.outcome == 'success'
                  ? Icons.check_circle_outline
                  : e.outcome == 'denied'
                      ? Icons.block
                      : Icons.error_outline,
              color: e.outcome == 'success' ? AppColors.safeGreen : AppColors.emergencyYellow,
              semanticLabel: e.outcome,
            ),
            title: Text('${e.action} · ${e.outcome}', style: TextStyle(color: OpsColors.text)),
            subtitle: Text(
              '${formatTimestamp(e.at)} · ${_actor(e)} · ${e.resourceType}${e.resourceId != null ? ' ${e.resourceId}' : ''}',
              style: TextStyle(color: OpsColors.textMuted),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    e.metadata.isEmpty ? 'No metadata' : const JsonEncoder.withIndent('  ').convert(e.metadata),
                    style: TextStyle(color: OpsColors.textMuted, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: _nextBefore != null
                ? OutlinedButton.icon(
                    key: const Key('audit-load-more'),
                    onPressed: _loadingMore ? null : _loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Load older entries'),
                  )
                : Text('${_entries.length} shown · end of log', style: TextStyle(color: OpsColors.textMuted)),
          ),
        ),
      ],
    ));
  }
}
