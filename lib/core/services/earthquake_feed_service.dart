import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One officially-reported earthquake, from USGS or EMSC.
class OfficialEarthquake {
  final String id;
  final double magnitude;
  final String place;
  final double latitude;
  final double longitude;
  final DateTime time;
  final String source; // 'USGS' or 'EMSC'

  OfficialEarthquake({
    required this.id,
    required this.magnitude,
    required this.place,
    required this.latitude,
    required this.longitude,
    required this.time,
    required this.source,
  });
}

/// Polls USGS's and EMSC's real, public, no-signup earthquake feeds —
/// unlike GovernmentAlertFeedService (still an empty placeholder waiting
/// on an authority to hand over a URL), these are live endpoints today.
///
/// IMPORTANT: this is a cross-check signal, never a gate. Official feeds
/// can lag local detection by minutes; SeismicService's local STA/LTA
/// pipeline raises its own alert on local evidence alone and never waits
/// on this. When an official report does arrive that's close in time and
/// location to a local candidate, it upgrades confidence after the fact
/// (e.g. for the correlation Cloud Function, or a "this was confirmed by
/// USGS" follow-up notice) — it never delays or blocks the first warning.
class EarthquakeFeedService extends ChangeNotifier {
  // USGS: all earthquakes of any magnitude in the last hour, updated
  // every ~1 minute — no API key required.
  static const String _usgsUrl =
      'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson';

  // EMSC (European-Mediterranean Seismological Centre): recent events,
  // JSON format — no API key required. Useful alongside USGS for
  // South Asia/Nepal/India coverage.
  static const String _emscUrl =
      'https://www.seismicportal.eu/fdsnws/event/1/query?format=json&limit=50&orderby=time';

  Timer? _pollTimer;
  final List<OfficialEarthquake> _recent = [];

  List<OfficialEarthquake> get recentEarthquakes => List.unmodifiable(_recent);

  void start({Duration interval = const Duration(minutes: 2)}) {
    _poll();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void stop() => _pollTimer?.cancel();

  /// Returns official events within [radiusKm] of a point and within
  /// [window] of a given time — used to cross-check a local candidate.
  List<OfficialEarthquake> nearMatches({
    required double latitude,
    required double longitude,
    required DateTime around,
    double radiusKm = 100,
    Duration window = const Duration(minutes: 10),
  }) {
    return _recent.where((eq) {
      final timeDiff = eq.time.difference(around).abs();
      if (timeDiff > window) return false;
      return _haversineKm(latitude, longitude, eq.latitude, eq.longitude) <= radiusKm;
    }).toList();
  }

  Future<void> _poll() async {
    await Future.wait([_pollUsgs(), _pollEmsc()]);
  }

  Future<void> _pollUsgs() async {
    try {
      final response =
          await http.get(Uri.parse(_usgsUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List;
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>;
        final geom = f['geometry'] as Map<String, dynamic>;
        final coords = geom['coordinates'] as List;
        _upsert(OfficialEarthquake(
          id: 'usgs_${f['id']}',
          magnitude: (props['mag'] as num?)?.toDouble() ?? 0,
          place: props['place'] as String? ?? 'Unknown location',
          latitude: (coords[1] as num).toDouble(),
          longitude: (coords[0] as num).toDouble(),
          time: DateTime.fromMillisecondsSinceEpoch(props['time'] as int),
          source: 'USGS',
        ));
      }
    } catch (e) {
      // A slow/unreachable official feed must never affect local
      // detection — swallow and try again next poll.
      debugPrint('USGS feed poll error: $e');
    }
  }

  Future<void> _pollEmsc() async {
    try {
      final response =
          await http.get(Uri.parse(_emscUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List? ?? [];
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>;
        final geom = f['geometry'] as Map<String, dynamic>;
        final coords = geom['coordinates'] as List;
        _upsert(OfficialEarthquake(
          id: 'emsc_${props['unid'] ?? f['id']}',
          magnitude: (props['mag'] as num?)?.toDouble() ?? 0,
          place: props['flynn_region'] as String? ?? 'Unknown location',
          latitude: (coords[1] as num).toDouble(),
          longitude: (coords[0] as num).toDouble(),
          time: DateTime.tryParse(props['time'] as String? ?? '') ?? DateTime.now(),
          source: 'EMSC',
        ));
      }
    } catch (e) {
      debugPrint('EMSC feed poll error: $e');
    }
  }

  void _upsert(OfficialEarthquake eq) {
    _recent.removeWhere((e) => e.id == eq.id);
    _recent.add(eq);
    // Keep only the last few hours' worth so this doesn't grow forever.
    final cutoff = DateTime.now().subtract(const Duration(hours: 6));
    _recent.removeWhere((e) => e.time.isBefore(cutoff));
    notifyListeners();
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _rad(double deg) => deg * pi / 180;
}
