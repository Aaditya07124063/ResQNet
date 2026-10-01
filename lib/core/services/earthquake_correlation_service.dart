import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/earthquake_evidence.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';

/// What the ResQNet backend reported back for a candidate.
class SeismicCorroboration {
  const SeismicCorroboration({required this.deviceCount, required this.corroborated});

  /// Distinct nearby ResQNet devices (including this one) that reported a
  /// candidate within a few seconds.
  final int deviceCount;
  final bool corroborated;
}

/// Reports a local earthquake candidate to the ResQNet backend
/// (`POST /api/v1/seismic/reports`), which clusters reports from nearby
/// devices and alerts other users when enough of them agree
/// (backend/src/services/seismicService.ts). Replaces the former Firestore
/// `seismic_events` write and its Cloud Function.
///
/// This is a SEPARATE signal from the local detector: a strong local
/// reading raises the on-device warning and SOS countdown on its own;
/// corroboration never gates it.
///
/// Best-effort and never queued: corroboration only means something within
/// seconds of the event, so a report that cannot be sent right away
/// (offline, not signed in, no location) is dropped rather than replayed
/// later as a stale "earthquake".
class EarthquakeCorrelationService {
  EarthquakeCorrelationService({
    @visibleForTesting Future<Position?> Function()? lastKnownPosition,
  }) : _lastKnownPosition = lastKnownPosition ?? Geolocator.getLastKnownPosition;

  final Future<Position?> Function() _lastKnownPosition;

  Future<SeismicCorroboration?> reportCandidate(EarthquakeEvidence evidence) async {
    Position? position;
    try {
      position = await _lastKnownPosition();
    } catch (_) {}
    if (position == null) {
      debugPrint('Earthquake candidate not reported: no location');
      return null;
    }

    try {
      final response = await ApiClient.instance.post(
        '/seismic/reports',
        auth: true,
        body: {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'detectorScore': evidence.totalConfidence.clamp(0.0, 1.0),
          if (evidence.staLtaRatio.isFinite) 'staLtaRatio': evidence.staLtaRatio.clamp(0.0, 1000.0),
          'sustainedDurationMs': evidence.sustainedDuration.inMilliseconds,
          'oscillationCount': evidence.oscillationCount,
        },
      );
      final result = response['result'] as Map<String, dynamic>?;
      if (result == null) return null;
      return SeismicCorroboration(
        deviceCount: (result['corroboratingDeviceCount'] as num?)?.toInt() ?? 1,
        corroborated: result['corroborated'] as bool? ?? false,
      );
    } on ApiException catch (e) {
      debugPrint('Earthquake candidate not reported: ${e.code}');
      return null;
    }
  }
}
