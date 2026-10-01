import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/incident_workflow.dart';
import '../../core/employee/operations_api.dart';
import '../../core/services/map/map_tile_provider.dart';
import 'incident_detail_page.dart';
import 'ops_common.dart';

/// Groups points into grid cells sized for the zoom level. Pure so it can be tested.
List<List<T>> clusterByGrid<T>(List<T> items, LatLng Function(T) position, double zoom) {
  final cell = 60 / math.pow(2, zoom.clamp(1, 20)); // degrees; ≈6 km at zoom 10
  final buckets = <String, List<T>>{};
  for (final item in items) {
    final p = position(item);
    final key = '${(p.latitude / cell).floor()}:${(p.longitude / cell).floor()}';
    buckets.putIfAbsent(key, () => []).add(item);
  }
  return buckets.values.toList();
}

/// Open incidents on a map. Positions come from the queue and are the
/// server's ≈1 km approximations for everyone; an employee with
/// SOS_RESPOND also sees the exact point of the incident they select.
/// Data refreshes on request or by polling — it is not live.
class IncidentMapPage extends StatefulWidget {
  const IncidentMapPage({super.key, this.pollInterval = const Duration(seconds: 60)});
  final Duration pollInterval;

  @override
  State<IncidentMapPage> createState() => _IncidentMapPageState();
}

class _IncidentMapPageState extends State<IncidentMapPage> {
  static const _limit = 200;
  static const _nepal = LatLng(28.3, 84.1);

  final _map = MapController();
  final MapTileProvider _tiles = resolveMapTileProvider();
  List<IncidentSummary> _incidents = const [];
  bool _truncated = false;
  bool _loading = true;
  Object? _error;
  DateTime? _refreshedAt;
  double _zoom = 7;
  IncidentSummary? _selected;
  IncidentDetail? _selectedDetail;
  bool _autoRefresh = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<OperationsApi>().listIncidents(scope: 'active', limit: _limit);
      if (!mounted) return;
      setState(() {
        _incidents = page.incidents.where((i) => i.latitude != null && i.longitude != null).toList();
        _truncated = page.nextCursor != null;
        _refreshedAt = DateTime.now();
        if (_selected != null && !_incidents.any((i) => i.id == _selected!.id)) {
          _selected = null;
          _selectedDetail = null;
        }
      });
    } catch (e) {
      if (!mounted || handleSessionError(context, e)) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(IncidentSummary incident) async {
    setState(() {
      _selected = incident;
      _selectedDetail = null;
    });
    // Exact position only for employees the server will give it to.
    if (!context.read<EmployeeSession>().can(sosRespondPermission)) return;
    try {
      final detail = await context.read<OperationsApi>().incident(incident.id);
      if (mounted && _selected?.id == incident.id) setState(() => _selectedDetail = detail);
    } catch (e) {
      if (mounted) handleSessionError(context, e);
    }
  }

  void _setAutoRefresh(bool on) {
    _poll?.cancel();
    _poll = on ? Timer.periodic(widget.pollInterval, (_) => _loading ? null : _load()) : null;
    setState(() => _autoRefresh = on);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpsPageHeader(
          title: 'Incident map',
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Open incidents at approximate (≈1 km) positions. Not live: refresh manually or enable polling.',
                style: TextStyle(color: OpsColors.textMuted),
              ),
              RefreshedStamp(refreshedAt: _refreshedAt),
              if (_truncated)
                const Text('Showing the $_limit most recent open incidents; use the queue for the rest.',
                    style: TextStyle(color: AppColors.emergencyYellow)),
            ],
          ),
          actions: [
            MergeSemantics(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(key: const Key('map-auto-refresh'), value: _autoRefresh, onChanged: _setAutoRefresh),
              Text('Poll every ${widget.pollInterval.inSeconds} s', style: TextStyle(color: OpsColors.textMuted)),
            ])),
            FilledButton.tonalIcon(
                onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(describeApiError(_error!), style: const TextStyle(color: AppColors.emergencyYellow)),
          ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final map = _mapView();
            final panel = _panel();
            if (wide) return Row(children: [Expanded(child: map), SizedBox(width: 340, child: panel)]);
            return Column(children: [Expanded(child: map), if (_selected != null) SizedBox(height: 230, child: panel)]);
          }),
        ),
      ],
    );
  }

  Widget _mapView() {
    final clusters = clusterByGrid<IncidentSummary>(_incidents, (i) => LatLng(i.latitude!, i.longitude!), _zoom);
    final exact = _selectedDetail;
    return Semantics(
      label:
          'Map of ${_incidents.length} open incidents. Use the list panel or the incident queue for keyboard access.',
      child: FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: _nepal,
          initialZoom: _zoom,
          onPositionChanged: (camera, _) {
            if ((camera.zoom - _zoom).abs() >= 0.5) setState(() => _zoom = camera.zoom);
          },
        ),
        children: [
          TileLayer(
              urlTemplate: _tiles.urlTemplate,
              userAgentPackageName: _tiles.userAgentPackageName,
              maxZoom: _tiles.maxZoom.toDouble()),
          MarkerLayer(markers: [
            for (final group in clusters) group.length == 1 ? _incidentMarker(group.first) : _clusterMarker(group),
            if (exact != null && exact.latitude != null && exact.includesSensitiveDetails)
              Marker(
                point: LatLng(exact.latitude!, exact.longitude!),
                width: 36,
                height: 36,
                child: const Tooltip(
                    message: 'Exact position (restricted)',
                    child: Icon(Icons.gps_fixed, color: Colors.white, size: 30)),
              ),
          ]),
          RichAttributionWidget(attributions: [
            TextSourceAttribution(
              _tiles.attributionText,
              onTap: _tiles.attributionUrl.startsWith('https://')
                  ? () => launchUrl(Uri.parse(_tiles.attributionUrl))
                  : null,
            ),
          ]),
        ],
      ),
    );
  }

  Marker _incidentMarker(IncidentSummary i) {
    final (icon, color) = switch (i.opsStatus) {
      'reported' => (Icons.priority_high, AppColors.emergencyRed),
      'acknowledged' => (Icons.visibility, AppColors.emergencyOrange),
      'assigned' => (Icons.person_pin_circle, AppColors.emergencyYellow),
      _ => (Icons.directions_run, AppColors.accentBlue),
    };
    final selected = _selected?.id == i.id;
    return Marker(
      key: ValueKey('map-marker-${i.id}'),
      point: LatLng(i.latitude!, i.longitude!),
      width: 40,
      height: 40,
      child: Tooltip(
        message: '${responderStateLabel(i.opsStatus)} · ${civilianStateLabel(i.civilianState)} · ${i.category}',
        child: GestureDetector(
          onTap: () => _select(i),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: selected ? 3 : 1.5),
            ),
            child: Icon(icon, color: Colors.black, size: 22),
          ),
        ),
      ),
    );
  }

  Marker _clusterMarker(List<IncidentSummary> group) {
    final lat = group.map((i) => i.latitude!).reduce((a, b) => a + b) / group.length;
    final lng = group.map((i) => i.longitude!).reduce((a, b) => a + b) / group.length;
    final unacknowledged = group.where((i) => i.opsStatus == 'reported').length;
    return Marker(
      point: LatLng(lat, lng),
      width: 48,
      height: 48,
      child: Tooltip(
        message: '${group.length} incidents ($unacknowledged unacknowledged). Zoom in to separate them.',
        child: GestureDetector(
          onTap: () => _map.move(LatLng(lat, lng), math.min(_zoom + 2, 18)),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: unacknowledged > 0 ? AppColors.emergencyRed : AppColors.accentBlue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Text('${group.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }

  Widget _panel() {
    final i = _selected;
    return Container(
      color: OpsColors.surface,
      child: i == null
          ? ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text('${_incidents.length} open incidents with a location',
                    style: TextStyle(color: OpsColors.text, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (_incidents.isEmpty && !_loading)
                  Text('No open incidents with a location.',
                      key: const Key('map-empty'), style: TextStyle(color: OpsColors.textMuted)),
                for (final incident in _incidents)
                  ListTile(
                    dense: true,
                    title: Text('${incident.category} · ${responderStateLabel(incident.opsStatus)}',
                        style: TextStyle(color: OpsColors.text)),
                    subtitle: Text(
                        '${formatAge(incident.receivedAt)} ago · ${civilianStateLabel(incident.civilianState)}',
                        style: TextStyle(color: OpsColors.textMuted)),
                    onTap: () {
                      _select(incident);
                      _map.move(LatLng(incident.latitude!, incident.longitude!), math.max(_zoom, 12));
                    },
                  ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Row(children: [
                  Expanded(
                      child: Text('Incident ${shortId(i.id)}',
                          style: TextStyle(color: OpsColors.text, fontWeight: FontWeight.w600))),
                  IconButton(
                      tooltip: 'Back to list',
                      onPressed: () => setState(() => _selected = null),
                      icon: const Icon(Icons.close)),
                ]),
                Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [ResponderStateChip(i.opsStatus), CivilianStateChip(i.civilianState)]),
                const SizedBox(height: 8),
                FieldRow('Received', '${formatTimestamp(i.receivedAt)} (${formatAge(i.receivedAt)} ago)'),
                FieldRow('Category', i.category),
                FieldRow('Approx. position', '${i.latitude!.toStringAsFixed(2)}, ${i.longitude!.toStringAsFixed(2)}'),
                if (_selectedDetail?.includesSensitiveDetails == true && _selectedDetail!.latitude != null)
                  FieldRow('Exact position',
                      '${_selectedDetail!.latitude!.toStringAsFixed(6)}, ${_selectedDetail!.longitude!.toStringAsFixed(6)}'),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const Key('map-open-incident'),
                  onPressed: () async {
                    await Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => IncidentDetailPage(incidentId: i.id)));
                    if (mounted) _load();
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open incident'),
                ),
              ],
            ),
    );
  }
}
