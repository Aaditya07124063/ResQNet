import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_outbox_entry.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/connectivity_status_service.dart';
import '../../core/services/emergency_outbox_store.dart';
import '../../core/services/location_service.dart';
import '../../core/services/mesh_service.dart';
import 'sos_status.dart';

/// Rebuilds [builder] once a second with the active SOS's current delivery
/// status (elapsed time ticks every second; the persisted outbox entry is
/// re-read every few seconds). Only runs while mounted.
class ActiveSosStatusBuilder extends StatefulWidget {
  const ActiveSosStatusBuilder({super.key, required this.alert, required this.builder});

  final SosAlert alert;
  final Widget Function(BuildContext context, Duration elapsed, List<SosStatusLine> lines) builder;

  @override
  State<ActiveSosStatusBuilder> createState() => _ActiveSosStatusBuilderState();
}

class _ActiveSosStatusBuilderState extends State<ActiveSosStatusBuilder> {
  Timer? _ticker;
  EmergencyOutboxEntry? _entry;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _loadEntry();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_ticks % 3 == 0) _loadEntry();
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(ActiveSosStatusBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alert.id != widget.alert.id) _loadEntry();
  }

  Future<void> _loadEntry() async {
    final entry = await EmergencyOutboxStore.instance.get(widget.alert.id);
    if (mounted) setState(() => _entry = entry);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final location = context.watch<LocationService>();
    final connectivity = context.watch<ConnectivityStatusService>();
    final reached = mesh.peersReachedFor(widget.alert.id);
    final lines = describeActiveSos(
      alert: widget.alert,
      entry: _entry,
      meshPeersReached: reached > 0 ? reached : _entry?.sentToPeerIds.length ?? 0,
      meshConnectedPeers: mesh.connectedCount,
      meshRunning: mesh.isAdvertising || mesh.isDiscovering,
      hasNetwork: connectivity.hasNetwork,
      locationStatus: location.status,
    );
    return widget.builder(context, DateTime.now().difference(widget.alert.timestamp), lines);
  }
}

/// One status line: icon + label + text (never colour alone).
class SosStatusRow extends StatelessWidget {
  const SosStatusRow({super.key, required this.line});

  final SosStatusLine line;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (line.tone) {
      SosStatusTone.good => (Icons.check_circle, AppColors.safeGreen),
      SosStatusTone.pending => (Icons.schedule, AppColors.warningAmber),
      SosStatusTone.problem => (Icons.error, AppColors.emergencyOrange),
    };
    return Semantics(
      container: true,
      label: '${line.label}: ${line.value}',
      excludeSemantics: line.action == null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.label,
                      style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(line.value, style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                  if (line.action == SosStatusAction.openLocationSettings)
                    TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 40)),
                      onPressed: () => context.read<LocationService>().openSettingsForStatus(),
                      child: const Text('Open location settings'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
