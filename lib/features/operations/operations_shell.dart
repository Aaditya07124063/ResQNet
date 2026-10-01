import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/operations_api.dart';
import '../../core/employee/sms_provider_admin.dart';
import '../employee/sms_providers_screen.dart';
import 'admin_pages.dart';
import 'alerts_page.dart';
import 'dashboard_page.dart';
import 'incident_map_page.dart';
import 'incident_queue_page.dart';

class OperationsSection {
  const OperationsSection(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

/// Sections this employee may open. The backend enforces the same
/// permissions on every request; hiding a section is only for clarity.
/// Civilian groups are private to their members, so there is no staff
/// "Groups" section.
List<OperationsSection> visibleSections(EmployeeSession session) {
  final monitor = session.can(sosMonitorPermission);
  final alertViewer = monitor || alertPublishPermissionFor.values.any(session.can);
  return [
    if (monitor) const OperationsSection('dashboard', 'Dashboard', Icons.space_dashboard_outlined),
    if (monitor) const OperationsSection('incidents', 'Incidents', Icons.sos_outlined),
    if (monitor) const OperationsSection('map', 'Map', Icons.map_outlined),
    if (alertViewer) const OperationsSection('alerts', 'Alerts', Icons.campaign_outlined),
    if (alertViewer) const OperationsSection('sources', 'Disaster sources', Icons.satellite_alt_outlined),
    if (session.can(sosAssignPermission)) const OperationsSection('responders', 'Responders', Icons.badge_outlined),
    if (session.can(smsProviderManagePermission)) const OperationsSection('sms', 'SMS providers', Icons.sms_outlined),
    if (session.can(auditLogViewPermission)) const OperationsSection('audit', 'Audit log', Icons.history),
    const OperationsSection('account', 'Account', Icons.account_circle_outlined),
  ];
}

class OperationsShell extends StatefulWidget {
  const OperationsShell({super.key});

  @override
  State<OperationsShell> createState() => _OperationsShellState();
}

class _OperationsShellState extends State<OperationsShell> {
  String? _selectedId;
  QueueFilter _queueFilter = const QueueFilter();
  int _queueGeneration = 0;

  void _select(String id) => setState(() => _selectedId = id);

  void _openQueue(QueueFilter filter) => setState(() {
        _queueFilter = filter;
        _queueGeneration++;
        _selectedId = 'incidents';
      });

  Widget _page(String id, EmployeeSession session) {
    final alertViewer = session.can(sosMonitorPermission) || alertPublishPermissionFor.values.any(session.can);
    return switch (id) {
      'dashboard' => DashboardPage(onOpenQueue: _openQueue, canViewAlerts: alertViewer),
      'incidents' => IncidentQueuePage(key: ValueKey('queue-$_queueGeneration'), initialFilter: _queueFilter),
      'map' => const IncidentMapPage(),
      'alerts' => const AlertsPage(),
      'sources' => const DisasterSourcesPage(),
      'responders' => const RespondersPage(),
      'sms' => const SmsProvidersScreen(),
      'audit' => const AuditLogPage(),
      _ => const AccountPage(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<EmployeeSession>();
    final sections = visibleSections(session);
    final selected = sections.firstWhere((s) => s.id == _selectedId, orElse: () => sections.first);
    final onlyAccount = sections.length == 1;
    final page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onlyAccount)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'Your account has no operations permissions yet. Ask an administrator to grant SOS_MONITOR or another permission.',
              key: Key('ops-no-permissions'),
              style: TextStyle(color: AppColors.emergencyYellow),
            ),
          ),
        Expanded(child: _page(selected.id, session)),
      ],
    );

    return OpsThemed(child: LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 840;
      if (wide) {
        final extended = constraints.maxWidth >= 1200;
        return Scaffold(
          backgroundColor: OpsColors.background,
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  key: const Key('ops-nav-rail'),
                  backgroundColor: OpsColors.surface,
                  extended: extended,
                  labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Semantics(
                      header: true,
                      child: Text(extended ? 'ResQNet Operations' : 'ResQNet',
                          style: TextStyle(color: OpsColors.text, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  destinations: [
                    for (final s in sections)
                      NavigationRailDestination(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          icon: Icon(s.icon),
                          label: Text(s.label, key: Key('ops-nav-${s.id}'))),
                  ],
                  selectedIndex: sections.indexOf(selected),
                  onDestinationSelected: (i) => _select(sections[i].id),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        backgroundColor: OpsColors.background,
        appBar: AppBar(
          backgroundColor: OpsColors.surface,
          foregroundColor: OpsColors.text,
          title: Text('Operations · ${selected.label}'),
        ),
        drawer: NavigationDrawer(
          key: const Key('ops-nav-drawer'),
          selectedIndex: sections.indexOf(selected),
          onDestinationSelected: (i) {
            Navigator.of(context).pop();
            _select(sections[i].id);
          },
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 16, 10),
              child: Text('ResQNet Operations', style: TextStyle(color: OpsColors.text, fontWeight: FontWeight.bold)),
            ),
            for (final s in sections)
              NavigationDrawerDestination(icon: Icon(s.icon), label: Text(s.label, key: Key('ops-nav-${s.id}'))),
          ],
        ),
        body: SafeArea(child: page),
      );
    }));
  }
}
