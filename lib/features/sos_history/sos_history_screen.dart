import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
import '../../core/models/emergency_outbox_entry.dart';
import '../../core/services/sos_service.dart';
import '../sos/sos_status.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/services/ai_service.dart';
import '../../core/services/emergency_communication_service.dart';
import '../../widgets/trust_tier_badge.dart';

/// Phase 20: reads the caller's own SOS history from the ResQNet backend
/// (`GET /api/v1/sos`, Phase 11) instead of Firestore's
/// `sos_history/{uid}/messages`. The backend's `SosEvent` shape (category
/// + free-text message + status + timestamps) has no `type`/`priority`/
/// icon/color fields the way the old Firestore-stored `EmergencyMessage`
/// did — those were derived client-side via [AiService] at broadcast
/// time and persisted alongside it. Here they're re-derived the same way,
/// from the same category/message text, purely for display styling; nothing
/// about the underlying SOS record depends on this classification.
///
/// **Known gap, not invented around**: swipe-to-delete / "clear all" from
/// the old Firestore version have no backend equivalent — Phase 11
/// deliberately did not add a DELETE endpoint for `sos_events` (an
/// emergency record is treated as an audit trail, not user-erasable data;
/// `status` transitions exist instead of deletion). Removed from this
/// screen rather than left as dead buttons that call nothing.
class SosHistoryScreen extends StatefulWidget {
  const SosHistoryScreen({super.key});

  @override
  State<SosHistoryScreen> createState() => _SosHistoryScreenState();
}

class _SosHistoryScreenState extends State<SosHistoryScreen> {
  late Future<List<_HistoryEntry>> _future;

  /// Shown above the list when the server copy could not be loaded but
  /// this device's own records could.
  String? _notice;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// This device's own SOS records (available offline) merged with the
  /// server's history, one row per event id.
  Future<List<_HistoryEntry>> _load() async {
    final ai = context.read<AiService>();
    final local = await context.read<SosService>().localHistory();

    List<Map<String, dynamic>> remote = const [];
    String? notice;
    try {
      final response = await ApiClient.instance.get('/sos', auth: true);
      remote = (response['events'] as List).cast<Map<String, dynamic>>();
    } on ApiException catch (e) {
      if (local.isEmpty) rethrow;
      notice = e.isNetworkError
          ? 'Offline — showing SOS alerts stored on this phone.'
          : 'Could not load your full history from the server — showing SOS alerts stored on this phone.';
    }
    if (mounted) setState(() => _notice = notice);

    EmergencyMessage toMessage(String id, String? text, double? lat, double? lng, DateTime at) {
      final message = text ?? '';
      final type = ai.classifyEmergency(message);
      return EmergencyMessage(
        id: id,
        senderId: '',
        senderName: '',
        message: message,
        type: type,
        priority: ai.assessPriority(message, type),
        latitude: lat,
        longitude: lng,
        timestamp: at,
      );
    }

    final localById = {for (final entry in local) entry.eventId: entry};
    final entries = <_HistoryEntry>[];
    final seen = <String>{};
    for (final e in remote) {
      final eventId = (e['eventId'] as String?) ?? (e['id'] as String);
      seen.add(eventId);
      final localEntry = localById[eventId];
      entries.add(_HistoryEntry(
        toMessage(eventId, e['message'] as String?, (e['latitude'] as num?)?.toDouble(),
            (e['longitude'] as num?)?.toDouble(), DateTime.parse(e['clientCreatedAt'] as String)),
        e['status'] as String,
        e['originVerificationState'] as String?,
        detail: localEntry != null && localEntry.isResolved ? describeResolution(localEntry) : null,
      ));
    }
    for (final entry in local) {
      if (seen.contains(entry.eventId)) continue;
      entries.add(_HistoryEntry(
        toMessage(entry.eventId, entry.message, entry.latitude, entry.longitude, entry.createdAt),
        _localStatus(entry),
        null,
        detail: entry.isResolved ? describeResolution(entry) : _localDetail(entry),
      ));
    }
    entries.sort((a, b) => b.message.timestamp.compareTo(a.message.timestamp));
    return entries;
  }

  String _localStatus(EmergencyOutboxEntry entry) {
    if (entry.resolution == SosResolution.falseAlarm) return 'false alarm';
    if (entry.isResolved) return 'resolved';
    switch (entry.state) {
      case OutboxEntryState.serverAccepted:
      case OutboxEntryState.deliveryConfirmed:
        return 'sent';
      case OutboxEntryState.failed:
        return 'not accepted';
      case OutboxEntryState.expired:
        return 'expired';
      default:
        return 'waiting to send';
    }
  }

  String? _localDetail(EmergencyOutboxEntry entry) {
    final peers = entry.sentToPeerIds.length;
    final mesh = peers > 0 ? 'Handed to $peers nearby device${peers == 1 ? '' : 's'} over the mesh. ' : '';
    switch (entry.state) {
      case OutboxEntryState.failed:
      case OutboxEntryState.expired:
        return '${mesh}Not recorded by the ResQNet server.';
      case OutboxEntryState.serverAccepted:
      case OutboxEntryState.deliveryConfirmed:
        return mesh.isEmpty ? null : mesh.trim();
      default:
        return '${mesh}Will be sent to the server when online.';
    }
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('SOS History',
            style: TextStyle(
                color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: FutureBuilder<List<_HistoryEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child:
                  CircularProgressIndicator(color: AppColors.emergencyRed),
            );
          }

          if (snapshot.hasError) {
            final isNetwork =
                snapshot.error is ApiException && (snapshot.error as ApiException).isNetworkError;
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline,
                      color: AppColors.textSecondary, size: 64),
                  const SizedBox(height: 16),
                  Text(
                    isNetwork
                        ? 'Could not reach the server. Check your connection.'
                        : 'Could not load SOS history.',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _refresh,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final entries = snapshot.data ?? [];

          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history,
                      color: AppColors.textSecondary, size: 64),
                  const SizedBox(height: 16),
                  Text('No SOS history yet',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Your sent SOS alerts will appear here',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 14)),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length + (_notice != null ? 1 : 0),
              itemBuilder: (_, index) {
                if (_notice != null && index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off, color: AppColors.warningAmber, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_notice!, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        ),
                      ],
                    ),
                  );
                }
                final i = _notice != null ? index - 1 : index;
                final msg = entries[i].message;
                final status = entries[i].status;

                return Card(
                  key: Key(msg.id),
                  color: AppColors.cardDark,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 110,
                        decoration: BoxDecoration(
                          color: msg.priorityColor,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            bottomLeft: Radius.circular(12),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(msg.typeIcon,
                                      color: msg.priorityColor, size: 18),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      msg.type.name.toUpperCase(),
                                      style: TextStyle(
                                          color: msg.priorityColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13),
                                    ),
                                  ),
                                  Container(
                                    constraints: const BoxConstraints(maxWidth: 140),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: msg.priorityColor.withValues(alpha: 0.15),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      border: Border.all(
                                          color: msg.priorityColor
                                              .withValues(alpha: 0.5)),
                                    ),
                                    child: Text(
                                      status.toUpperCase(),
                                      style: TextStyle(
                                          color: msg.priorityColor,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                msg.message,
                                style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 13),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.access_time,
                                      size: 12,
                                      color: AppColors.textSecondary),
                                  const SizedBox(width: 4),
                                  Text(
                                    DateFormat('dd MMM yyyy  HH:mm')
                                        .format(msg.timestamp),
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary),
                                  ),
                                  if (msg.latitude != null) ...[
                                    const SizedBox(width: 8),
                                    const Icon(Icons.location_on,
                                        size: 12,
                                        color: AppColors.accentBlue),
                                    const SizedBox(width: 2),
                                    const Text('GPS attached',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.accentBlue)),
                                  ],
                                ],
                              ),
                              if (entries[i].detail != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(entries[i].detail!,
                                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                ),
                              Builder(builder: (context) {
                                final tier = trustTierForBackendRecord(entries[i].originVerificationState);
                                if (tier == null) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: TrustTierBadge(tier: tier),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _HistoryEntry {
  final EmergencyMessage message;
  final String status;
  /// Raw `sos_events.origin_verification_state` from the backend (Phase 1):
  /// 'not_applicable' (the normal, JWT-authenticated online path — no
  /// mesh/signature involved), 'verified' (a mesh-relayed event whose
  /// signature the backend confirmed against a registered device key), or
  /// 'unverified_unregistered' (relayed, but the origin device has never
  /// registered a key — preserved, never attributed, never falsely shown
  /// as verified). Displayed precisely, never collapsed into a generic
  /// "verified" badge — see trustTierForBackendRecord()/TrustTierBadge.
  final String? originVerificationState;

  /// Delivery/cancellation detail from this device's own records.
  final String? detail;
  _HistoryEntry(this.message, this.status, this.originVerificationState, {this.detail});
}

// The trust badge itself now lives in widgets/trust_tier_badge.dart
// (TrustTierBadge) — the one shared place every screen renders this,
// fed here via emergency_communication_service.dart's
// trustTierForBackendRecord(), so this screen's wording can never drift
// from mesh_screen.dart's/dashboard_screen.dart's (via EmergencyCard).
