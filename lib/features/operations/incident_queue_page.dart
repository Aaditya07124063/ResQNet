import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/incident_workflow.dart';
import '../../core/employee/operations_api.dart';
import 'incident_detail_page.dart';
import 'ops_common.dart';

/// Filters the dashboard can open the queue with.
class QueueFilter {
  const QueueFilter({this.scope = 'active', this.opsStatus, this.civilianState, this.assignee});
  final String scope;
  final String? opsStatus;
  final String? civilianState;

  /// null = anyone, 'me', or 'unassigned'.
  final String? assignee;
}

/// The incident queue: records in the ResQNet operations system, newest
/// first, a page at a time (cursor pagination — never the whole table).
class IncidentQueuePage extends StatefulWidget {
  const IncidentQueuePage(
      {super.key, this.initialFilter = const QueueFilter(), this.pollInterval = const Duration(seconds: 30)});

  final QueueFilter initialFilter;
  final Duration pollInterval;

  @override
  State<IncidentQueuePage> createState() => _IncidentQueuePageState();
}

class _IncidentQueuePageState extends State<IncidentQueuePage> {
  static const _pageSize = 50;

  late String _scope = widget.initialFilter.scope;
  late String? _opsStatus = widget.initialFilter.opsStatus;
  late String? _civilianState = widget.initialFilter.civilianState;
  late String? _assignee = widget.initialFilter.assignee;

  final List<IncidentSummary> _incidents = [];
  String? _nextCursor;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  DateTime? _refreshedAt;
  bool _autoRefresh = false;
  Timer? _pollTimer;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _load();
    // Re-evaluates ages and the stale-data warning.
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  String? get _assigneeParam {
    if (_assignee == 'me') return context.read<EmployeeSession>().employee?.id;
    return _assignee;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<OperationsApi>().listIncidents(
            scope: _scope,
            opsStatus: _opsStatus,
            civilianState: _civilianState,
            assignee: _assigneeParam,
            limit: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _incidents
          ..clear()
          ..addAll(page.incidents);
        _nextCursor = page.nextCursor;
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
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<OperationsApi>().listIncidents(
            scope: _scope,
            opsStatus: _opsStatus,
            civilianState: _civilianState,
            assignee: _assigneeParam,
            cursor: cursor,
            limit: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _incidents.addAll(page.incidents);
        _nextCursor = page.nextCursor;
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeApiError(e))));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _setAutoRefresh(bool on) {
    _pollTimer?.cancel();
    _pollTimer = on ? Timer.periodic(widget.pollInterval, (_) => _loading ? null : _load()) : null;
    setState(() => _autoRefresh = on);
  }

  void _applyFilter(VoidCallback change) {
    setState(change);
    _load();
  }

  Future<void> _open(IncidentSummary incident) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => IncidentDetailPage(incidentId: incident.id)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpsPageHeader(
          title: 'Incidents',
          subtitle: RefreshedStamp(refreshedAt: _refreshedAt),
          actions: [
            MergeSemantics(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                key: const Key('queue-auto-refresh'),
                value: _autoRefresh,
                onChanged: _setAutoRefresh,
              ),
              Text('Refresh every ${widget.pollInterval.inSeconds} s', style: TextStyle(color: OpsColors.textMuted)),
            ])),
            FilledButton.tonalIcon(
              key: const Key('queue-refresh'),
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        _filters(),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _filters() {
    DropdownMenuItem<String?> item(String? value, String label) => DropdownMenuItem(value: value, child: Text(label));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<String>(
            key: const Key('queue-scope'),
            segments: const [
              ButtonSegment(value: 'active', label: Text('Open')),
              ButtonSegment(value: 'closed', label: Text('Closed')),
              ButtonSegment(value: 'all', label: Text('All')),
            ],
            selected: {_scope},
            onSelectionChanged: (s) => _applyFilter(() => _scope = s.first),
          ),
          _labelledDropdown(
            'Responder state',
            DropdownButton<String?>(
              key: const Key('queue-filter-ops'),
              value: _opsStatus,
              items: [item(null, 'Any'), for (final s in responderStates) item(s, responderStateLabel(s))],
              onChanged: (v) => _applyFilter(() => _opsStatus = v),
            ),
          ),
          _labelledDropdown(
            'Reporter',
            DropdownButton<String?>(
              key: const Key('queue-filter-civilian'),
              value: _civilianState,
              items: [
                item(null, 'Any'),
                for (final s in ['active', 'safe', 'cancelled']) item(s, civilianStateLabel(s))
              ],
              onChanged: (v) => _applyFilter(() => _civilianState = v),
            ),
          ),
          _labelledDropdown(
            'Assignment',
            DropdownButton<String?>(
              key: const Key('queue-filter-assignee'),
              value: _assignee,
              items: [item(null, 'Anyone'), item('me', 'Assigned to me'), item('unassigned', 'Unassigned')],
              onChanged: (v) => _applyFilter(() => _assignee = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelledDropdown(String label, Widget dropdown) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text('$label: ', style: TextStyle(color: OpsColors.textMuted)), dropdown],
      );

  Widget _body() {
    if (_loading && _incidents.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _incidents.isEmpty) return ErrorPanel(error: _error!, onRetry: _load);
    if (_incidents.isEmpty) {
      return MessagePanel(
        icon: Icons.inbox_outlined,
        title: _scope == 'active' ? 'No open incidents' : 'No incidents match',
        message: 'There are no records in the ResQNet operations system for these filters.',
        onRetry: _load,
      );
    }
    final myId = context.watch<EmployeeSession>().employee?.id;
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Refresh failed: ${describeApiError(_error!)}',
                    style: const TextStyle(color: AppColors.emergencyYellow)),
              ),
            if (wide) _table(myId) else ..._incidents.map((i) => _card(i, myId)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _nextCursor != null
                    ? OutlinedButton.icon(
                        key: const Key('queue-load-more'),
                        onPressed: _loadingMore ? null : _loadMore,
                        icon: _loadingMore
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.expand_more),
                        label: const Text('Load more'),
                      )
                    : Text('${_incidents.length} shown · end of list', style: TextStyle(color: OpsColors.textMuted)),
              ),
            ),
          ],
        ),
      );
    });
  }

  String _assignment(IncidentSummary i, String? myId) {
    if (i.assignedEmployeeId == null) return 'Unassigned';
    return i.assignedEmployeeId == myId ? 'Assigned to you' : 'Assigned';
  }

  String _location(IncidentSummary i) => i.sensitiveRemoved
      ? 'Removed (retention)'
      : i.latitude == null
          ? 'No location'
          : '≈ ${i.latitude!.toStringAsFixed(2)}, ${i.longitude!.toStringAsFixed(2)}';

  String _source(IncidentSummary i) {
    final source = i.eventSource.replaceAll('_', ' ');
    return i.originVerificationState == 'verified' ? '$source · relayed, verified' : source;
  }

  Widget _table(String? myId) {
    TextStyle cell = TextStyle(color: OpsColors.text);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DataTable(
        key: const Key('queue-table'),
        showCheckboxColumn: false,
        headingTextStyle: TextStyle(color: OpsColors.textMuted, fontWeight: FontWeight.w600),
        columns: const [
          DataColumn(label: Text('Incident')),
          DataColumn(label: Text('Received')),
          DataColumn(label: Text('Age')),
          DataColumn(label: Text('Responder state')),
          DataColumn(label: Text('Reporter')),
          DataColumn(label: Text('Category')),
          DataColumn(label: Text('Source')),
          DataColumn(label: Text('Approx. location')),
          DataColumn(label: Text('Assignment')),
        ],
        rows: [
          for (final i in _incidents)
            DataRow(
              key: ValueKey('queue-row-${i.id}'),
              onSelectChanged: (_) => _open(i),
              cells: [
                DataCell(Text(shortId(i.id), style: cell.copyWith(fontFamily: 'monospace'))),
                DataCell(Text(formatTimestamp(i.receivedAt), style: cell)),
                DataCell(Text(formatAge(i.receivedAt), style: cell)),
                DataCell(ResponderStateChip(i.opsStatus)),
                DataCell(CivilianStateChip(i.civilianState)),
                DataCell(Text(i.category, style: cell)),
                DataCell(Text(_source(i), style: cell)),
                DataCell(Text(_location(i), style: cell)),
                DataCell(Text(_assignment(i, myId), style: cell)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _card(IncidentSummary i, String? myId) {
    return Card(
      key: ValueKey('queue-card-${i.id}'),
      color: OpsColors.card,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => _open(i),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [ResponderStateChip(i.opsStatus), CivilianStateChip(i.civilianState)]),
              const SizedBox(height: 8),
              Text('${i.category} · ${_source(i)}',
                  style: TextStyle(color: OpsColors.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${formatTimestamp(i.receivedAt)} (${formatAge(i.receivedAt)} ago) · ${_location(i)} · ${_assignment(i, myId)}',
                style: TextStyle(color: OpsColors.textMuted),
              ),
              Text('Incident ${shortId(i.id)}', style: TextStyle(color: OpsColors.textMuted, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
