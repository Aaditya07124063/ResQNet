import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import '../models/earthquake_evidence.dart';

/// Reports local seismic candidates to Firestore so a Cloud Function can
/// cluster them across nearby devices — the same shape as
/// Seismic-Network's approach (3+ devices, ~50km radius, within a short
/// time window raises confidence dramatically over any single phone's
/// reading). This is a SEPARATE signal from the local STA/LTA detector:
/// a strong local reading still raises the first warning on its own —
/// multi-device confirmation refines confidence, it doesn't gate the
/// first alert.
///
/// Requires a new `notifyEarthquakeCorroboration`-style Cloud Function
/// (not yet written) to actually do the clustering — this service only
/// writes the candidate; nothing reads the corroboration count back yet.
class EarthquakeCorrelationService {
  Future<void> reportCandidate(EarthquakeEvidence evidence) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      Position? position;
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (_) {}

      await FirebaseFirestore.instance.collection('seismic_events').doc(const Uuid().v4()).set({
        'userId': uid,
        'timestamp': DateTime.now().toIso8601String(),
        'latitude': position?.latitude,
        'longitude': position?.longitude,
        'confidence': evidence.totalConfidence,
        'staLtaRatio': evidence.staLtaRatio,
        'sustainedDurationMs': evidence.sustainedDuration.inMilliseconds,
        'oscillationCount': evidence.oscillationCount,
      });
    } catch (e) {
      debugPrint('EarthquakeCorrelationService report error: $e');
    }
  }
}
