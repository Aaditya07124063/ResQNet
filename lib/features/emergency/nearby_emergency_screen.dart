import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/emergency_communication_service.dart';
import '../../core/services/nearby_alert_service.dart';
import '../../widgets/trust_tier_badge.dart';

/// D. Nearby emergency screen (Section 16) — what a nearby ResQNet user
/// sees after an FCM/WebSocket `nearby_sos_created` alert. Deliberately
/// shows only the minimum necessary information (Section 12): category,
/// an approximate distance bucket, and when it happened — never the
/// reporter's identity, message, or exact location. The person seeing
/// this is a nearby ResQNet user, not a "responder" (Section 16D) — no
/// verified-responder role exists in this system yet.
class NearbyEmergencyScreen extends StatefulWidget {
  final String sosEventId;

  const NearbyEmergencyScreen({super.key, required this.sosEventId});

  @override
  State<NearbyEmergencyScreen> createState() => _NearbyEmergencyScreenState();
}

class _NearbyEmergencyScreenState extends State<NearbyEmergencyScreen> {
  final _service = NearbyAlertService();
  NearbyEmergencyDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail = await _service.getDetail(widget.sosEventId);
      if (mounted) setState(() => _detail = detail);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'This emergency is no longer available, or you were not alerted about it.');
      }
    }
  }

  String _categoryLabel(String category) {
    switch (category) {
      case 'medical':
        return 'Medical emergency';
      case 'fire':
        return 'Fire';
      case 'flood':
        return 'Flood';
      case 'earthquake':
        return 'Earthquake';
      case 'trapped':
        return 'Trapped';
      case 'rescue':
        return 'Rescue needed';
      default:
        return 'General emergency';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Emergency Nearby',
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
              ),
            )
          : _detail == null
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.emergencyRed.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.emergencyRed.withValues(alpha: 0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.warning_amber_rounded, color: AppColors.emergencyRed, size: 28),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text('🚨 Emergency nearby',
                                      style: TextStyle(
                                          color: AppColors.emergencyRed,
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _DetailRow(label: 'Type', value: _categoryLabel(_detail!.category)),
                            _DetailRow(label: 'Distance', value: _detail!.approximateDistance),
                            _DetailRow(
                                label: 'Reported', value: DateFormat.yMMMd().add_jm().format(_detail!.activatedAt)),
                            _DetailRow(label: 'Status', value: _detail!.status.replaceAll('_', ' ')),
                            const SizedBox(height: 8),
                            // This endpoint (getNearbyEmergencyDetail) deliberately
                            // never exposes origin_verification_state to a
                            // non-trusted-contact viewer (Section 12's
                            // minimum-necessary-detail design) — so this screen
                            // genuinely has no stronger trust signal available and
                            // must never guess one. Always UNVERIFIED here, using
                            // the same shared badge as every other screen.
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: TrustTierBadge(tier: EmergencyTrustTier.transportOnly),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'For privacy, ResQNet only shares an approximate distance and category for '
                        'a nearby emergency — not the exact location or who reported it.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      // Trust-tier precision (Section 14/33): this screen
                      // only ever shows an event the backend has already
                      // recorded and fanned out — that is BACKEND
                      // AUTHENTICATED, and, separately, nothing here
                      // confirms the reporter's exact location, that the
                      // emergency is genuine, or that any rescue team has
                      // been notified. Never collapse these into one
                      // generic "verified" claim.
                      Text(
                        'This alert was received through the ResQNet network. It does not confirm '
                        'the reporter\'s exact location, that the emergency is genuine, or that a '
                        'rescue team has been notified.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                      const Spacer(),
                      Text(
                        'If you can help, contact local emergency services directly.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
