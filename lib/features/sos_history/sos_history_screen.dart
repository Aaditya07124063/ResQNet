import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
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

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_HistoryEntry>> _load() async {
    final ai = context.read<AiService>();
    final response = await ApiClient.instance.get('/sos', auth: true);
    final events = (response['events'] as List).cast<Map<String, dynamic>>();
    return events.map((e) {
      final message = (e['message'] as String?) ?? '';
      final type = ai.classifyEmergency(message);
      final priority = ai.assessPriority(message, type);
      final msg = EmergencyMessage(
        id: e['id'] as String,
        senderId: '',
        senderName: '',
        message: message,
        type: type,
        priority: priority,
        latitude: (e['latitude'] as num?)?.toDouble(),
        longitude: (e['longitude'] as num?)?.toDouble(),
        timestamp: DateTime.parse(e['clientCreatedAt'] as String),
      );
      return _HistoryEntry(msg, e['status'] as String, e['originVerificationState'] as String?);
    }).toList();
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
              itemCount: entries.length,
              itemBuilder: (_, i) {
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
                        height: 90,
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
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: msg.priorityColor.withOpacity(0.15),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      border: Border.all(
                                          color: msg.priorityColor
                                              .withOpacity(0.5)),
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
  _HistoryEntry(this.message, this.status, this.originVerificationState);
}

// The trust badge itself now lives in widgets/trust_tier_badge.dart
// (TrustTierBadge) — the one shared place every screen renders this,
// fed here via emergency_communication_service.dart's
// trustTierForBackendRecord(), so this screen's wording can never drift
// from mesh_screen.dart's/dashboard_screen.dart's (via EmergencyCard).
