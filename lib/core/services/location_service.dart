import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Why a location is or is not available — surfaced in the SOS UI so a
/// user under stress sees "Location permission denied" rather than a
/// generic failure, and knows what to fix.
enum LocationStatus {
  unknown,
  acquiring,
  available,
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled,
  unavailable,
}

class LocationService extends ChangeNotifier {
  Position? _currentPosition;
  bool _isTracking = false;
  LocationStatus _status = LocationStatus.unknown;
  StreamSubscription<Position>? _trackingSubscription;

  Position? get currentPosition => _currentPosition;
  bool get isTracking => _isTracking;
  LocationStatus get status => _status;
  double? get latitude => _currentPosition?.latitude;
  double? get longitude => _currentPosition?.longitude;

  void _setStatus(LocationStatus status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }

  Future<bool> requestPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setStatus(LocationStatus.serviceDisabled);
        return false;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _setStatus(LocationStatus.permissionDeniedForever);
        return false;
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.unableToDetermine) {
        _setStatus(LocationStatus.permissionDenied);
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Location permission check failed: $e');
      _setStatus(LocationStatus.unavailable);
      return false;
    }
  }

  Future<Position?> getCurrentLocation({Duration timeout = const Duration(seconds: 8)}) async {
    final hasPermission = await requestPermission();
    if (!hasPermission) return null;
    _setStatus(LocationStatus.acquiring);
    try {
      _currentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(timeout);
      _status = LocationStatus.available;
      notifyListeners();
      return _currentPosition;
    } catch (e) {
      debugPrint('Location error: $e, falling back to last known position');
      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) _currentPosition = lastKnown;
        _status = _currentPosition != null ? LocationStatus.available : LocationStatus.unavailable;
        notifyListeners();
        return lastKnown;
      } catch (_) {
        _setStatus(LocationStatus.unavailable);
        return null;
      }
    }
  }

  /// For time-critical callers (SOS): returns a fix no older than [maxAge]
  /// immediately if one is cached, otherwise waits at most [timeout] for a
  /// fresh one — an SOS must not sit behind a long GPS wait when a recent
  /// position is already known.
  Future<Position?> getBestEffortLocation({
    Duration maxAge = const Duration(minutes: 2),
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final cached = _currentPosition;
    if (cached != null && DateTime.now().difference(cached.timestamp) <= maxAge) {
      return cached;
    }
    return getCurrentLocation(timeout: timeout);
  }

  // Alias used by home_screen
  Future<Position?> getCurrentPosition() => getCurrentLocation();

  Future<bool> openSettingsForStatus() {
    return _status == LocationStatus.serviceDisabled ? Geolocator.openLocationSettings() : Geolocator.openAppSettings();
  }

  void startTracking() {
    if (_trackingSubscription != null) return;
    _isTracking = true;
    _trackingSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(
      (position) {
        _currentPosition = position;
        _status = LocationStatus.available;
        notifyListeners();
      },
      onError: (Object e) => debugPrint('Location stream error: $e'),
    );
  }

  void stopTracking() {
    _trackingSubscription?.cancel();
    _trackingSubscription = null;
    _isTracking = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _trackingSubscription?.cancel();
    super.dispose();
  }
}
