import 'package:flutter/foundation.dart';
import '../network/api_client.dart';

/// Client for the nearby-emergency-alert preference and detail endpoints
/// (`/api/v1/nearby-alerts/*`, `/api/v1/sos/:id/nearby-detail`) —
/// deliberately its own service, not part of [CommunicationService]: a
/// nearby SOS is an emergency event, not a chat message (Section 17).
class NearbyAlertService extends ChangeNotifier {
  bool _enabled = false;
  int? _radiusM;
  bool _loaded = false;

  bool get enabled => _enabled;
  int? get radiusM => _radiusM;
  bool get loaded => _loaded;

  Future<void> loadPreference() async {
    try {
      final result = await ApiClient.instance.get('/nearby-alerts/preference');
      final pref = result['preference'] as Map<String, dynamic>;
      _enabled = pref['enabled'] as bool? ?? false;
      _radiusM = pref['radiusM'] as int?;
    } catch (e) {
      debugPrint('loadPreference failed: $e');
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Turning this ON does not, by itself, start any location tracking —
  /// the caller (e.g. the settings screen or HomeScreen's periodic ping)
  /// still has to call [pingLocation] for the preference to have any
  /// effect. Turning it OFF deletes any stored approximate location
  /// server-side immediately (see nearbyAlertService.ts's own comment).
  Future<void> setPreference({required bool enabled, int? radiusM}) async {
    final result = await ApiClient.instance.put(
      '/nearby-alerts/preference',
      body: {'enabled': enabled, if (radiusM != null) 'radiusM': radiusM},
    );
    final pref = result['preference'] as Map<String, dynamic>;
    _enabled = pref['enabled'] as bool? ?? false;
    _radiusM = pref['radiusM'] as int?;
    notifyListeners();
  }

  /// A one-shot approximate-location update — the server silently no-ops
  /// (returns `stored: false`) if the preference is off, so this is safe
  /// to call opportunistically (e.g. once per app foreground) without
  /// checking [enabled] first.
  Future<void> pingLocation(double latitude, double longitude) async {
    try {
      await ApiClient.instance.put(
        '/nearby-alerts/location',
        body: {'latitude': latitude, 'longitude': longitude},
      );
    } catch (e) {
      debugPrint('Nearby-alert location ping failed: $e');
    }
  }

  Future<NearbyEmergencyDetail> getDetail(String sosEventId) async {
    final result = await ApiClient.instance.get('/sos/$sosEventId/nearby-detail');
    return NearbyEmergencyDetail.fromJson(result['detail'] as Map<String, dynamic>);
  }
}

/// The minimum-necessary detail a nearby (non-trusted-contact) recipient
/// is authorized to see (Section 12) — no reporter identity, message, or
/// exact coordinates, matching sosService.ts's getNearbyEmergencyDetail
/// exactly.
class NearbyEmergencyDetail {
  final String sosEventId;
  final String category;
  final String status;
  final String approximateDistance;
  final DateTime activatedAt;

  const NearbyEmergencyDetail({
    required this.sosEventId,
    required this.category,
    required this.status,
    required this.approximateDistance,
    required this.activatedAt,
  });

  factory NearbyEmergencyDetail.fromJson(Map<String, dynamic> json) => NearbyEmergencyDetail(
        sosEventId: json['sosEventId'] as String,
        category: json['category'] as String,
        status: json['status'] as String,
        approximateDistance: json['approximateDistance'] as String,
        activatedAt: DateTime.parse(json['activatedAt'] as String),
      );
}
