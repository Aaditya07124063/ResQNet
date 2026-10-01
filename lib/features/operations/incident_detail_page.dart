import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/incident_workflow.dart';
import '../../core/employee/operations_api.dart';
import '../../core/network/api_exception.dart';
import 'ops_common.dart';

/// One incident: state, location and contact (as permitted), the responder
/// actions this employee may take, and the full timeline. Every action is
/// validated again by the backend.
class IncidentDetailPage extends StatefulWidget {
  const IncidentDetailPage({super.key, required this.incidentId});
  final String incidentId;

  @override
  State<IncidentDetailPage> createState() => _IncidentDetailPageState();
}

class _IncidentDetailPageState extends State<IncidentDetailPage> {
  IncidentDetail? _incident;
  Object? _error;
  bool _loading = true;
  bool _acting = false;
  DateTime? _refreshedAt;
  Map<String, EligibleResponder> _responders = const {};
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  IncidentActor get _actor {
    final session = context.read<EmployeeSession>();
    return IncidentActor(
      employeeId: session.employee?.id ?? '',
      canRespond: session.can(sosRespondPermission),
      canAssign: session.can(sosAssignPermission),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<OperationsApi>();
    final canAssign = _actor.canAssign;
    try {
      final incident = await api.incident(widget.incidentId);
      Map<String, EligibleResponder> responders = _responders;
      if (canAssign) {
        try {
          responders = {for (final r in await api.responders()) r.id: r};
        } on ApiException {
          // Names are a convenience; the incident itself loaded.
        }
      }
      if (!mounted) return;
      setState(() {
        _incident = incident;
        _responders = responders;
        _refreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _nameOf(String? employeeId) {
    if (employeeId == null) return null;
    if (employeeId == context.read<EmployeeSession>().employee?.id) return 'You';
    return _responders[employeeId]?.displayName;
  }

  Future<void> _submit(String action, {String? note, String? assignee, required String doneMessage}) async {
    setState(() => _acting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context
          .read<OperationsApi>()
          .recordUpdate(widget.incidentId, action, note: note, assignedEmployeeId: assignee);
      messenger.showSnackBar(SnackBar(content: Text(doneMessage)));
      _note.clear();
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      final conflict = e is ApiException && e.statusCode == 409;
      messenger.showSnackBar(SnackBar(
        content: Text(conflict ? '${describeApiError(e)} — the incident was reloaded.' : describeApiError(e)),
      ));
    } finally {
      if (mounted) {
        setState(() => _acting = false);
        await _load();
      }
    }
  }

  Future<void> _transition(String to) async {
    final incident = _incident!;
    final reassign = to == 'assigned' && incident.summary.assignedEmployeeId != null;
    if (to == 'assigned') return _assign(reassign: reassign);
    if (to == 'stood_down') return _standDown();
    final ok = await confirmAction(
      context,
      title: actionLabel(to),
      message: 'Change the responder state from ${responderStateLabel(incident.summary.opsStatus)} '
          'to ${responderStateLabel(to)}? This is recorded in the incident timeline and audit log.',
      confirmLabel: actionLabel(to),
    );
    if (ok) await _submit(to, doneMessage: 'Recorded: ${responderStateLabel(to)}');
  }

  Future<void> _assign({required bool reassign}) async {
    final current = _incident!.summary.assignedEmployeeId;
    final candidates = _responders.values.where((r) => r.id != current).toList();
    final picked = await showDialog<EligibleResponder>(
      context: context,
      builder: (dialogContext) =>
          _AssignDialog(candidates: candidates, reassign: reassign, currentName: _nameOf(current)),
    );
    if (picked == null || !mounted) return;
    final ok = await confirmAction(
      context,
      title: reassign ? 'Reassign incident' : 'Assign incident',
      message: '${reassign ? 'Reassign' : 'Assign'} this incident to ${picked.displayName}?',
      confirmLabel: reassign ? 'Reassign' : 'Assign',
    );
    if (ok) await _submit('assigned', assignee: picked.id, doneMessage: 'Assigned to ${picked.displayName}');
  }

  Future<void> _standDown() async {
    final reason = await showDialog<String>(context: context, builder: (_) => const _StandDownDialog());
    if (reason == null || !mounted) return;
    await _submit('stood_down', note: reason, doneMessage: 'Incident stood down');
  }

  @override
  Widget build(BuildContext context) {
    final incident = _incident;
    return OpsThemed(
        child: Scaffold(
      backgroundColor: OpsColors.background,
      appBar: AppBar(
        backgroundColor: OpsColors.surface,
        foregroundColor: OpsColors.text,
        title: Text(incident == null ? 'Incident' : 'Incident ${shortId(incident.summary.id)}'),
        actions: [
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: incident == null
            ? (_loading
                ? const Center(child: CircularProgressIndicator())
                : ErrorPanel(error: _error ?? 'Unknown', onRetry: _load))
            : _content(incident),
      ),
    ));
  }

  Widget _content(IncidentDetail incident) {
    final s = incident.summary;
    final open = !terminalResponderStates.contains(s.opsStatus);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1000;
      final left = [
        _header(incident),
        if (open && s.civilianState != 'active') _civilianBanner(incident),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Refresh failed: ${describeApiError(_error!)}',
                style: const TextStyle(color: AppColors.emergencyYellow)),
          ),
        _actions(incident),
        _details(incident),
        _location(incident),
        _reporter(incident),
        _retention(incident),
      ];
      final right = [_timeline(incident)];
      if (!wide) return ListView(padding: const EdgeInsets.only(bottom: 24), children: [...left, ...right]);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: ListView(padding: const EdgeInsets.only(bottom: 24), children: left)),
          Expanded(flex: 4, child: ListView(padding: const EdgeInsets.only(bottom: 24), children: right)),
        ],
      );
    });
  }

  Widget _header(IncidentDetail incident) {
    final s = incident.summary;
    return OpsPageHeader(
      title: '${s.category[0].toUpperCase()}${s.category.substring(1)} SOS',
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [ResponderStateChip(s.opsStatus), CivilianStateChip(s.civilianState)]),
          const SizedBox(height: 6),
          RefreshedStamp(refreshedAt: _refreshedAt),
        ],
      ),
    );
  }

  Widget _civilianBanner(IncidentDetail incident) {
    final changedAt = incident.timeline.where((t) => t.isCivilian).lastOrNull?.at;
    final what = incident.summary.civilianState == 'safe' ? 'marked themselves safe' : 'cancelled the SOS';
    return Container(
      key: const Key('incident-civilian-banner'),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.emergencyYellow),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        const Icon(Icons.info_outline, color: AppColors.emergencyYellow),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'The reporter $what${changedAt != null ? ' at ${formatTimestamp(changedAt)}' : ''}. '
            'The incident stays open until a responder resolves it or stands it down.',
            style: TextStyle(color: OpsColors.text),
          ),
        ),
      ]),
    );
  }

  Widget _actions(IncidentDetail incident) {
    final s = incident.summary;
    final actor = _actor;
    final transitions =
        availableTransitions(opsStatus: s.opsStatus, assignedEmployeeId: s.assignedEmployeeId, actor: actor);
    final reassign = s.assignedEmployeeId != null;
    final terminal = terminalResponderStates.contains(s.opsStatus);
    return OpsCard(
      title: 'Actions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!actor.canRespond)
            Text('View only: recording responder actions needs the SOS_RESPOND permission.',
                key: const Key('incident-view-only'), style: TextStyle(color: OpsColors.textMuted))
          else if (terminal)
            Text('This incident is ${responderStateLabel(s.opsStatus).toLowerCase()}. Only notes can be added.',
                style: TextStyle(color: OpsColors.textMuted))
          else if (transitions.isEmpty)
            Text(
              s.assignedEmployeeId == null
                  ? 'Waiting for assignment by a dispatcher (SOS_ASSIGN).'
                  : 'Progress is recorded by the assigned responder or a dispatcher.',
              style: TextStyle(color: OpsColors.textMuted),
            ),
          if (transitions.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final to in transitions)
                  to == 'stood_down'
                      ? OutlinedButton.icon(
                          key: Key('incident-action-$to'),
                          onPressed: _acting ? null : () => _transition(to),
                          icon: const Icon(Icons.do_not_disturb_on_outlined),
                          label: Text(actionLabel(to)),
                        )
                      : FilledButton.icon(
                          key: Key('incident-action-$to'),
                          onPressed: _acting ? null : () => _transition(to),
                          icon: Icon(to == 'assigned' ? Icons.person_add_alt : Icons.arrow_forward),
                          label: Text(actionLabel(to, reassign: reassign)),
                        ),
              ],
            ),
          if (canAddNote(actor)) ...[
            const SizedBox(height: 16),
            TextField(
              key: const Key('incident-note'),
              controller: _note,
              maxLength: 1000,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Add a note',
                helperText: 'Operational facts only; avoid unnecessary medical detail.',
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('incident-add-note'),
                onPressed: _acting
                    ? null
                    : () {
                        final text = _note.text.trim();
                        if (text.isEmpty) return;
                        _submit('note', note: text, doneMessage: 'Note added');
                      },
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('Add note'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _details(IncidentDetail incident) {
    final s = incident.summary;
    return OpsCard(
      title: 'Incident',
      child: Column(children: [
        FieldRow('Incident ID', s.id),
        FieldRow('Device event ID', s.eventId),
        FieldRow('Received', '${formatTimestamp(s.receivedAt)} (${formatAge(s.receivedAt)} ago)'),
        FieldRow('Category', s.category),
        FieldRow('Trigger', s.eventSource.replaceAll('_', ' ')),
        FieldRow(
          'Origin',
          switch (s.originVerificationState) {
            'verified' => 'Relayed by another phone; sender signature verified',
            'unverified' => 'Relayed; sender could not be verified',
            _ => 'Sent directly by the reporter\'s signed-in device',
          },
        ),
        FieldRow('Assigned to',
            s.assignedEmployeeId == null ? 'Nobody' : (_nameOf(s.assignedEmployeeId) ?? 'Another responder')),
      ]),
    );
  }

  static const _removedText = 'Removed under the retention policy';

  Widget _location(IncidentDetail incident) {
    final exact = incident.includesSensitiveDetails;
    final removed = incident.summary.sensitiveRemoved;
    final lat = incident.latitude;
    return OpsCard(
      title: 'Location',
      child: Column(children: [
        if (removed)
          const FieldRow('Location', _removedText, key: Key('incident-location-removed'))
        else if (lat == null)
          const FieldRow('Location', 'The device did not report a location')
        else ...[
          FieldRow(
            exact ? 'Exact position' : 'Approximate (≈1 km)',
            '${lat.toStringAsFixed(exact ? 6 : 2)}, ${incident.longitude!.toStringAsFixed(exact ? 6 : 2)}',
          ),
          if (exact && incident.locationAccuracyM != null)
            FieldRow('Reported accuracy', '± ${incident.locationAccuracyM!.round()} m'),
        ],
        if (!exact && !removed)
          Text('The exact position is shown to employees with SOS_RESPOND.',
              key: const Key('incident-location-restricted'),
              style: TextStyle(color: OpsColors.textMuted, fontSize: 12)),
      ]),
    );
  }

  Widget _reporter(IncidentDetail incident) {
    final exact = incident.includesSensitiveDetails;
    final removed = incident.summary.sensitiveRemoved;
    final deidentified = incident.lifecycle.deidentifiedAt != null;
    return OpsCard(
      title: 'Reporter',
      child: Column(children: [
        if (deidentified)
          const FieldRow('Account', 'Link to the account removed under the retention policy')
        else if (!incident.hasReporterAccount)
          const FieldRow('Account', 'None (relayed without a verified sender)')
        else ...[
          FieldRow('Name', incident.reporterName),
          FieldRow('Phone', exact ? (incident.reporterPhone ?? 'Not on file') : 'Restricted'),
        ],
        FieldRow(
            'SOS message',
            removed
                ? _removedText
                : exact
                    ? (incident.message ?? 'No message')
                    : 'Restricted'),
        if (!exact && !removed)
          Text('Phone number, SOS message and responder notes are shown to employees with SOS_RESPOND.',
              key: const Key('incident-contact-restricted'),
              style: TextStyle(color: OpsColors.textMuted, fontSize: 12)),
      ]),
    );
  }

  Widget _retention(IncidentDetail incident) {
    final life = incident.lifecycle;
    final canHold = context.read<EmployeeSession>().can(retentionHoldManagePermission);
    return OpsCard(
      title: 'Record retention',
      child: Column(
        key: const Key('incident-retention'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldRow('Closed by responders',
              life.closedAt == null ? 'Not yet — nothing is removed while open' : formatTimestamp(life.closedAt)),
          FieldRow(
              'Personal details removed',
              life.sensitiveRedactedAt == null
                  ? (incident.summary.sensitiveRemoved ? 'Due — no longer shown' : 'Not yet')
                  : formatTimestamp(life.sensitiveRedactedAt)),
          FieldRow(
              'Account link removed', life.deidentifiedAt == null ? 'Not yet' : formatTimestamp(life.deidentifiedAt)),
          FieldRow(
              'Retention hold', life.onHold ? 'Since ${formatTimestamp(life.holdSince)}: ${life.holdReason}' : 'None'),
          Text('A hold pauses removal for this record. It is an operational flag, not a legal determination.',
              style: TextStyle(color: OpsColors.textMuted, fontSize: 12)),
          if (canHold && life.deidentifiedAt == null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('incident-retention-hold'),
              onPressed: _acting ? null : () => _toggleHold(life.onHold),
              icon: Icon(life.onHold ? Icons.lock_open : Icons.lock_clock),
              label: Text(life.onHold ? 'Release hold' : 'Place hold'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggleHold(bool currentlyHeld) async {
    String? reason;
    if (!currentlyHeld) {
      reason = await showDialog<String>(context: context, builder: (_) => const _HoldReasonDialog());
      if (reason == null || !mounted) return;
    } else {
      final ok = await confirmAction(context,
          title: 'Release hold',
          message: 'Let this record follow the normal retention periods again?',
          confirmLabel: 'Release');
      if (!ok || !mounted) return;
    }
    setState(() => _acting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<OperationsApi>().setRetentionHold(widget.incidentId, hold: !currentlyHeld, reason: reason);
      messenger.showSnackBar(SnackBar(content: Text(currentlyHeld ? 'Hold released' : 'Hold placed')));
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      messenger.showSnackBar(SnackBar(content: Text(describeApiError(e))));
    } finally {
      if (mounted) {
        setState(() => _acting = false);
        await _load();
      }
    }
  }

  Widget _timeline(IncidentDetail incident) {
    final s = incident.summary;
    return OpsCard(
      title: 'Timeline',
      child: Column(
        key: const Key('incident-timeline'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TimelineTile(
            icon: Icons.sos,
            who: 'System',
            text: 'SOS received by the ResQNet server',
            at: s.receivedAt,
            civilian: false,
          ),
          for (final entry in incident.timeline)
            _TimelineTile(
              icon: entry.isCivilian
                  ? Icons.person_outline
                  : entry.action == 'note'
                      ? Icons.sticky_note_2_outlined
                      : Icons.badge_outlined,
              who: entry.isCivilian
                  ? 'Reporter'
                  : 'Responder${entry.actorRole != null ? ' · ${entry.actorRole!.replaceAll('_', ' ')}' : ''}',
              text: describeTimelineEntry(entry, nameOf: _nameOf),
              detail: entry.note ??
                  (entry.noteRemoved
                      ? 'Note text removed under the retention policy'
                      : entry.noteHidden
                          ? 'Note text restricted (SOS_RESPOND)'
                          : null),
              at: entry.at,
              civilian: entry.isCivilian,
            ),
        ],
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile(
      {required this.icon,
      required this.who,
      required this.text,
      required this.at,
      required this.civilian,
      this.detail});

  final IconData icon;
  final String who;
  final String text;
  final String? detail;
  final DateTime at;
  final bool civilian;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: civilian ? AppColors.emergencyYellow.withValues(alpha: 0.08) : Colors.transparent,
          border:
              Border(left: BorderSide(color: civilian ? AppColors.emergencyYellow : AppColors.accentBlue, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: OpsColors.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$who · ${formatTimestamp(at)}', style: TextStyle(color: OpsColors.textMuted, fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(text, style: TextStyle(color: OpsColors.text)),
                  if (detail != null) ...[
                    const SizedBox(height: 4),
                    Text(detail!, style: TextStyle(color: OpsColors.textMuted, fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignDialog extends StatefulWidget {
  const _AssignDialog({required this.candidates, required this.reassign, this.currentName});
  final List<EligibleResponder> candidates;
  final bool reassign;
  final String? currentName;

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.reassign ? 'Reassign incident' : 'Assign incident'),
      content: SizedBox(
        width: 420,
        child: widget.candidates.isEmpty
            ? const Text('No other active employee holds SOS_RESPOND.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.reassign) Text('Currently assigned: ${widget.currentName ?? 'another responder'}'),
                  Flexible(
                    child: RadioGroup<String>(
                      groupValue: _selected,
                      onChanged: (v) => setState(() => _selected = v),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in widget.candidates)
                            RadioListTile<String>(
                              key: Key('assign-option-${r.id}'),
                              value: r.id,
                              title: Text(r.displayName),
                              subtitle:
                                  Text('${r.role.replaceAll('_', ' ')} · ${r.openAssignments} open assignment(s)'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('assign-continue'),
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, widget.candidates.firstWhere((r) => r.id == _selected)),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _StandDownDialog extends StatefulWidget {
  const _StandDownDialog();

  @override
  State<_StandDownDialog> createState() => _StandDownDialogState();
}

class _StandDownDialogState extends State<_StandDownDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _reason.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Stand down incident'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Closes the incident without responders attending. A reason is required and is kept in the timeline.'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('stand-down-reason'),
              controller: _reason,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('stand-down-confirm'),
          onPressed: valid ? () => Navigator.pop(context, _reason.text.trim()) : null,
          child: const Text('Stand down'),
        ),
      ],
    );
  }
}

class _HoldReasonDialog extends StatefulWidget {
  const _HoldReasonDialog();

  @override
  State<_HoldReasonDialog> createState() => _HoldReasonDialogState();
}

class _HoldReasonDialogState extends State<_HoldReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _reason.text.trim().length >= 3;
    return AlertDialog(
      title: const Text('Place retention hold'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'Pauses removal of this record\'s personal details and account link. Give the operational reason.'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('hold-reason'),
            controller: _reason,
            maxLength: 500,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('hold-confirm'),
          onPressed: valid ? () => Navigator.pop(context, _reason.text.trim()) : null,
          child: const Text('Place hold'),
        ),
      ],
    );
  }
}
