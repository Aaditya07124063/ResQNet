import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/operations_api.dart';
import '../../core/network/api_exception.dart';
import 'incident_queue_page.dart';
import 'ops_common.dart';

/// Current records in the ResQNet operations system, counted by the server.
/// Not real-world statistics: only SOS events that reached ResQNet.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.onOpenQueue, required this.canViewAlerts});

  final void Function(QueueFilter filter) onOpenQueue;
  final bool canViewAlerts;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  IncidentCounts? _counts;
  List<StaffAlert>? _alerts;
  Object? _alertsError;
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
    final api = context.read<OperationsApi>();
    try {
      final counts = await api.incidentCounts();
      List<StaffAlert>? alerts;
      Object? alertsError;
      if (widget.canViewAlerts) {
        try {
          alerts = (await api.alerts()).where((a) => a.status == 'active').take(5).toList();
        } on ApiException catch (e) {
          alertsError = e;
        }
      }
      if (!mounted) return;
      setState(() {
        _counts = counts;
        _alerts = alerts;
        _alertsError = alertsError;
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
    final counts = _counts;
    final name = context.watch<EmployeeSession>().employee?.displayName ?? '';
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        OpsPageHeader(
          title: 'Operations dashboard',
          subtitle: Text('Signed in as $name', style: TextStyle(color: OpsColors.textMuted)),
          actions: [
            RefreshedStamp(refreshedAt: _refreshedAt),
            FilledButton.tonalIcon(
              key: const Key('dashboard-refresh'),
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        if (counts == null)
          SizedBox(
            height: 320,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ErrorPanel(error: _error ?? 'Unknown', onRetry: _load),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Current records in the ResQNet operations system, counted by the server at '
              '${formatTimestamp(counts.generatedAt)}. These are SOS events that reached ResQNet — not real-world statistics.',
              key: const Key('dashboard-disclaimer'),
              style: TextStyle(color: OpsColors.textMuted),
            ),
          ),
          if (counts.open == 0)
            const Padding(
              padding: EdgeInsets.all(20),
              child: MessagePanel(
                  icon: Icons.inbox_outlined,
                  title: 'No open incidents',
                  message: 'Nothing is waiting for a responder right now.'),
            ),
          _grid(counts),
          if (counts.oldestUnacknowledgedAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                'Oldest unacknowledged incident received ${formatTimestamp(counts.oldestUnacknowledgedAt)} '
                '(${formatAge(counts.oldestUnacknowledgedAt!)} ago).',
                key: const Key('dashboard-oldest-unacknowledged'),
                style: const TextStyle(color: AppColors.emergencyYellow, fontWeight: FontWeight.w600),
              ),
            ),
          if (widget.canViewAlerts) _recentAlerts(),
        ],
      ],
    );
  }

  Widget _grid(IncidentCounts c) {
    final tiles = <_CountTile>[
      _CountTile('Open incidents', c.open, Icons.inbox, 'Not yet resolved or stood down', const QueueFilter()),
      _CountTile('Unacknowledged', c.count('reported'), Icons.priority_high, 'Nobody has acknowledged yet',
          const QueueFilter(opsStatus: 'reported')),
      _CountTile('Acknowledged', c.count('acknowledged'), Icons.visibility_outlined, 'Awaiting assignment',
          const QueueFilter(opsStatus: 'acknowledged')),
      _CountTile('Assigned', c.count('assigned'), Icons.person_pin_circle_outlined, 'Responder assigned',
          const QueueFilter(opsStatus: 'assigned')),
      _CountTile('En route', c.count('en_route'), Icons.directions_run, 'Responder travelling',
          const QueueFilter(opsStatus: 'en_route')),
      _CountTile('On scene', c.count('arrived'), Icons.place_outlined, 'Responder arrived',
          const QueueFilter(opsStatus: 'arrived')),
      _CountTile('Assisting', c.count('assisting'), Icons.medical_services_outlined, 'Help in progress',
          const QueueFilter(opsStatus: 'assisting')),
      _CountTile('Open, reporter safe', c.openButCivilianSafe, Icons.verified_user_outlined,
          'Still needs a responder decision', const QueueFilter(civilianState: 'safe')),
      _CountTile('Open, reporter cancelled', c.openButCivilianCancelled, Icons.cancel_outlined,
          'Still needs a responder decision', const QueueFilter(civilianState: 'cancelled')),
      _CountTile('Resolved', c.count('resolved'), Icons.check_circle_outline, 'All time',
          const QueueFilter(scope: 'closed', opsStatus: 'resolved')),
      _CountTile('Stood down', c.count('stood_down'), Icons.do_not_disturb_on_outlined, 'All time',
          const QueueFilter(scope: 'closed', opsStatus: 'stood_down')),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in tiles)
            SizedBox(
              width: 230,
              child: Card(
                key: Key('dashboard-count-${t.label}'),
                color: OpsColors.card,
                child: InkWell(
                  onTap: () => widget.onOpenQueue(t.filter),
                  child: Semantics(
                    button: true,
                    label: '${t.label}: ${t.value}. ${t.hint}. Opens the incident queue.',
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(t.icon, size: 18, color: OpsColors.textMuted),
                            const SizedBox(width: 6),
                            Expanded(child: Text(t.label, style: TextStyle(color: OpsColors.textMuted))),
                          ]),
                          const SizedBox(height: 6),
                          Text('${t.value}',
                              style: TextStyle(color: OpsColors.text, fontSize: 28, fontWeight: FontWeight.bold)),
                          Text(t.hint, style: TextStyle(color: OpsColors.textMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _recentAlerts() {
    final alerts = _alerts;
    return OpsCard(
      title: 'Active alerts (latest 5)',
      child: _alertsError != null
          ? Text(describeApiError(_alertsError!), style: TextStyle(color: OpsColors.textMuted))
          : alerts == null || alerts.isEmpty
              ? Text('No active alerts.',
                  key: const Key('dashboard-no-alerts'), style: TextStyle(color: OpsColors.textMuted))
              : Column(
                  children: [
                    for (final a in alerts)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(a.title, style: TextStyle(color: OpsColors.text)),
                        subtitle: Text('${a.sourceName} · ${a.severity} · issued ${formatTimestamp(a.issuedAt)}',
                            style: TextStyle(color: OpsColors.textMuted)),
                        trailing: SourceTypeChip(a.sourceType),
                      ),
                  ],
                ),
    );
  }
}

class _CountTile {
  const _CountTile(this.label, this.value, this.icon, this.hint, this.filter);
  final String label;
  final int value;
  final IconData icon;
  final String hint;
  final QueueFilter filter;
}
