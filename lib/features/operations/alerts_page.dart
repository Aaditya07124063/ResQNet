import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/operations_api.dart';
import 'ops_common.dart';

const _alertCategories = [
  'flood',
  'earthquake',
  'landslide',
  'wildfire',
  'storm',
  'avalanche',
  'evacuation',
  'shelter',
  'road_closure',
  'health',
  'other',
];
const _alertSeverities = ['info', 'advisory', 'watch', 'warning', 'emergency'];

/// Source types this employee may issue in the portal. The backend checks
/// the same permission again on every create and update.
List<String> publishableSourceTypes(EmployeeSession session) => [
      for (final e in alertPublishPermissionFor.entries)
        if (session.can(e.value)) e.key
    ];

/// Staff view of emergency alerts with their provenance. Only the server's
/// `sourceType` decides the label; nothing here can relabel an alert.
class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  List<StaffAlert>? _alerts;
  Object? _error;
  bool _loading = true;
  DateTime? _refreshedAt;
  String _status = 'active';

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
      final alerts = await context.read<OperationsApi>().alerts();
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        _refreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final created =
        await Navigator.of(context).push<StaffAlert>(MaterialPageRoute(builder: (_) => const AlertFormPage()));
    if (created != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Alert published: ${created.title}')));
      _load();
    }
  }

  Future<void> _setStatus(StaffAlert alert, String status) async {
    final ok = await confirmAction(
      context,
      title: status == 'resolved' ? 'Resolve alert' : 'Cancel alert',
      message:
          '${status == 'resolved' ? 'Mark' : 'Cancel'} "${alert.title}"${status == 'resolved' ? ' as resolved' : ''}? '
          'It stops being served to the app. This is audit-logged.',
      confirmLabel: status == 'resolved' ? 'Resolve' : 'Cancel alert',
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<OperationsApi>().updateAlert(alert.id, {'status': status});
      messenger.showSnackBar(const SnackBar(content: Text('Alert updated')));
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      messenger.showSnackBar(SnackBar(content: Text(describeApiError(e))));
    }
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<EmployeeSession>();
    final publishable = publishableSourceTypes(session);
    final alerts = _alerts;
    final shown = alerts?.where((a) => _status == 'all' || a.status == _status).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpsPageHeader(
          title: 'Alerts',
          subtitle: RefreshedStamp(refreshedAt: _refreshedAt),
          actions: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'active', label: Text('Active')),
                ButtonSegment(value: 'resolved', label: Text('Resolved')),
                ButtonSegment(value: 'cancelled', label: Text('Cancelled')),
                ButtonSegment(value: 'all', label: Text('All')),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
            FilledButton.tonalIcon(
                onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
            if (publishable.isNotEmpty)
              FilledButton.icon(
                  key: const Key('alerts-new'),
                  onPressed: _create,
                  icon: const Icon(Icons.add_alert),
                  label: const Text('New alert')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            publishable.isEmpty
                ? 'View only. Publishing needs an alert publish permission for the source type.'
                : 'You may publish: ${publishable.map(SourceTypeChip.labelFor).join(', ')}.',
            key: const Key('alerts-publish-scope'),
            style: TextStyle(color: OpsColors.textMuted),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: alerts == null
              ? (_loading
                  ? const Center(child: CircularProgressIndicator())
                  : ErrorPanel(error: _error ?? 'Unknown', onRetry: _load))
              : shown!.isEmpty
                  ? MessagePanel(
                      icon: Icons.notifications_none,
                      title: 'No ${_status == 'all' ? '' : '$_status '}alerts',
                      message: 'No external disaster source is connected, so only alerts issued by staff appear here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [for (final a in shown) _alertCard(a, session)],
                    ),
        ),
      ],
    );
  }

  Widget _alertCard(StaffAlert a, EmployeeSession session) {
    final permission = alertPublishPermissionFor[a.sourceType];
    final canEdit = permission != null && session.can(permission) && a.status == 'active';
    final area = [
      if (a.latitude != null)
        '${a.latitude!.toStringAsFixed(3)}, ${a.longitude!.toStringAsFixed(3)} · radius ${a.radiusKm} km',
      if (a.areaNames.isNotEmpty) a.areaNames.join(', '),
    ].join(' · ');
    return OpsCard(
      child: Column(
        key: ValueKey('alert-${a.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SourceTypeChip(a.sourceType),
            StatusChip(
                label: a.severity.toUpperCase(),
                icon: Icons.warning_amber_rounded,
                color: AppColors.emergencyOrange,
                tooltip: 'Severity'),
            StatusChip(label: a.status, icon: Icons.flag_outlined, color: OpsColors.textMuted, tooltip: 'Status'),
          ]),
          const SizedBox(height: 8),
          Text(a.title, style: TextStyle(color: OpsColors.text, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(a.body, style: TextStyle(color: OpsColors.textMuted)),
          const SizedBox(height: 8),
          FieldRow('Issuer', a.sourceName),
          FieldRow(
            'Provenance',
            a.retrievedAt != null
                ? 'Fetched from an external feed at ${formatTimestamp(a.retrievedAt)}'
                : 'Issued in the ResQNet portal by staff holding the ${SourceTypeChip.labelFor(a.sourceType)} publish permission',
          ),
          if (a.sourceUrl != null)
            FieldRow(
              'Source link',
              null,
              valueWidget: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: a.sourceUrl!.startsWith('https://') ? () => launchUrl(Uri.parse(a.sourceUrl!)) : null,
                  child: Text(a.sourceUrl!, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          FieldRow('Category', a.category.replaceAll('_', ' ')),
          FieldRow('Area', area.isEmpty ? '—' : area),
          FieldRow('Issued', formatTimestamp(a.issuedAt)),
          FieldRow('Expires', a.expiresAt == null ? 'No expiry set' : formatTimestamp(a.expiresAt)),
          FieldRow('Last updated', formatTimestamp(a.updatedAt)),
          if (canEdit)
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                key: Key('alert-resolve-${a.id}'),
                onPressed: () => _setStatus(a, 'resolved'),
                icon: const Icon(Icons.check),
                label: const Text('Resolve'),
              ),
              OutlinedButton.icon(
                  onPressed: () => _setStatus(a, 'cancelled'),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel alert')),
            ]),
        ],
      ),
    );
  }
}

/// Create an alert. The source-type choices are limited to what this
/// employee may publish; the server enforces the same rule.
class AlertFormPage extends StatefulWidget {
  const AlertFormPage({super.key});

  @override
  State<AlertFormPage> createState() => _AlertFormPageState();
}

class _AlertFormPageState extends State<AlertFormPage> {
  final _form = GlobalKey<FormState>();
  final _sourceName = TextEditingController();
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _instructions = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _radius = TextEditingController();
  final _district = TextEditingController();
  final _province = TextEditingController();
  final _sourceUrl = TextEditingController();
  String? _sourceType;
  String _category = 'flood';
  String _severity = 'warning';
  int? _expiresInHours = 24;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _sourceName,
      _title,
      _body,
      _instructions,
      _lat,
      _lng,
      _radius,
      _district,
      _province,
      _sourceUrl
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final circle = [_lat.text, _lng.text, _radius.text].where((t) => t.trim().isNotEmpty).length;
    if (circle != 0 && circle != 3) {
      setState(() => _error = 'Latitude, longitude and radius must be given together.');
      return;
    }
    if (circle == 0 && _district.text.trim().isEmpty && _province.text.trim().isEmpty) {
      setState(() => _error = 'Give a circle (latitude, longitude, radius) or a district/province.');
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Publish alert',
      message: 'Publish "${_title.text.trim()}" labelled ${SourceTypeChip.labelFor(_sourceType!)}? '
          'It is served to ResQNet apps immediately and audit-logged.',
      confirmLabel: 'Publish',
    );
    if (!ok || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final body = <String, dynamic>{
      'sourceType': _sourceType,
      'sourceName': _sourceName.text.trim(),
      'category': _category,
      'severity': _severity,
      'title': _title.text.trim(),
      'body': _body.text.trim(),
      if (opt(_instructions) != null) 'instructions': opt(_instructions),
      if (circle == 3) ...{
        'latitude': double.parse(_lat.text.trim()),
        'longitude': double.parse(_lng.text.trim()),
        'radiusKm': double.parse(_radius.text.trim()),
      },
      if (opt(_district) != null) 'district': opt(_district),
      if (opt(_province) != null) 'province': opt(_province),
      if (opt(_sourceUrl) != null) 'sourceUrl': opt(_sourceUrl),
      if (_expiresInHours != null)
        'expiresAt': DateTime.now().toUtc().add(Duration(hours: _expiresInHours!)).toIso8601String(),
    };
    final navigator = Navigator.of(context);
    try {
      final created = await context.read<OperationsApi>().createAlert(body);
      navigator.pop(created);
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      setState(() => _error = describeApiError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? v, {int min = 1}) =>
      (v == null || v.trim().length < min) ? 'Required (at least $min characters)' : null;

  String? _number(String? v, double min, double max) {
    if (v == null || v.trim().isEmpty) return null;
    final n = double.tryParse(v.trim());
    return n == null || n < min || n > max ? 'Enter a number between $min and $max' : null;
  }

  @override
  Widget build(BuildContext context) {
    final types = publishableSourceTypes(context.watch<EmployeeSession>());
    _sourceType ??= types.isEmpty ? null : types.first;
    Widget field(TextEditingController c, String label,
            {String? Function(String?)? validator, int maxLines = 1, int? maxLength, Key? key, String? helper}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            key: key,
            controller: c,
            validator: validator,
            maxLines: maxLines,
            maxLength: maxLength,
            decoration: InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder()),
          ),
        );
    return OpsThemed(
        child: Scaffold(
      backgroundColor: OpsColors.background,
      appBar:
          AppBar(backgroundColor: OpsColors.surface, foregroundColor: OpsColors.text, title: const Text('New alert')),
      body: types.isEmpty
          ? const MessagePanel(
              icon: Icons.lock_outline, title: 'Not permitted', message: 'You do not hold an alert publish permission.')
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('alert-source-type'),
                    initialValue: _sourceType,
                    decoration: const InputDecoration(
                        labelText: 'Source label',
                        border: OutlineInputBorder(),
                        helperText: 'Only the labels you are permitted to publish are listed.'),
                    items: [for (final t in types) DropdownMenuItem(value: t, child: Text(SourceTypeChip.labelFor(t)))],
                    onChanged: (v) => setState(() => _sourceType = v),
                  ),
                  const SizedBox(height: 12),
                  field(_sourceName, 'Issuer name',
                      key: const Key('alert-source-name'),
                      validator: (v) => _required(v, min: 2),
                      maxLength: 160,
                      helper: 'The organisation issuing this alert, exactly as it should be shown.'),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _category,
                        decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                        items: [
                          for (final c in _alertCategories)
                            DropdownMenuItem(value: c, child: Text(c.replaceAll('_', ' ')))
                        ],
                        onChanged: (v) => setState(() => _category = v!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _severity,
                        decoration: const InputDecoration(labelText: 'Severity', border: OutlineInputBorder()),
                        items: [for (final s in _alertSeverities) DropdownMenuItem(value: s, child: Text(s))],
                        onChanged: (v) => setState(() => _severity = v!),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  field(_title, 'Title',
                      key: const Key('alert-title'), validator: (v) => _required(v, min: 3), maxLength: 200),
                  field(_body, 'Message',
                      key: const Key('alert-body'), validator: _required, maxLines: 4, maxLength: 4000),
                  field(_instructions, 'Instructions (optional)', maxLines: 3, maxLength: 2000),
                  Text('Area: a circle, or a district/province', style: TextStyle(color: OpsColors.textMuted)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: field(_lat, 'Latitude', validator: (v) => _number(v, -90, 90))),
                    const SizedBox(width: 12),
                    Expanded(child: field(_lng, 'Longitude', validator: (v) => _number(v, -180, 180))),
                    const SizedBox(width: 12),
                    Expanded(child: field(_radius, 'Radius (km)', validator: (v) => _number(v, 0.01, 1000))),
                  ]),
                  Row(children: [
                    Expanded(child: field(_district, 'District')),
                    const SizedBox(width: 12),
                    Expanded(child: field(_province, 'Province')),
                  ]),
                  field(_sourceUrl, 'Source link (optional, https)', validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final uri = Uri.tryParse(v.trim());
                    return uri == null || uri.scheme != 'https' || uri.host.isEmpty ? 'Must be an https:// link' : null;
                  }),
                  DropdownButtonFormField<int?>(
                    initialValue: _expiresInHours,
                    decoration: const InputDecoration(labelText: 'Expires', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 6, child: Text('In 6 hours')),
                      DropdownMenuItem(value: 24, child: Text('In 24 hours')),
                      DropdownMenuItem(value: 72, child: Text('In 3 days')),
                      DropdownMenuItem(value: 168, child: Text('In 7 days')),
                      DropdownMenuItem(value: null, child: Text('No expiry')),
                    ],
                    onChanged: (v) => setState(() => _expiresInHours = v),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                        liveRegion: true,
                        child: Text(_error!,
                            key: const Key('alert-form-error'),
                            style: const TextStyle(color: AppColors.emergencyYellow))),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('alert-publish'),
                    onPressed: _saving ? null : _submit,
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Publish alert'),
                  ),
                ],
              ),
            ),
    ));
  }
}
