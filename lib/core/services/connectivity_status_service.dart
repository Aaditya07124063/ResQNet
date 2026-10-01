import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Whether this device has any Wi-Fi/mobile-data network interface up.
///
/// This is NOT proof that the internet or the ResQNet server is reachable
/// (a captive portal or dead uplink still reports "connected") — the UI
/// says "Network available", and backend reachability is judged from real
/// request outcomes (the SOS outbox), never from this alone.
class ConnectivityStatusService extends ChangeNotifier {
  ConnectivityStatusService({Connectivity? connectivity}) : _connectivity = connectivity;

  final Connectivity? _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool? _hasNetwork;
  bool _started = false;

  /// Null until the first reading arrives.
  bool? get hasNetwork => _hasNetwork;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final connectivity = _connectivity ?? Connectivity();
    try {
      _apply(await connectivity.checkConnectivity());
      _subscription = connectivity.onConnectivityChanged.listen(
        _apply,
        onError: (Object e) => debugPrint('Connectivity listener error: $e'),
      );
    } catch (e) {
      debugPrint('Connectivity unavailable: $e');
    }
  }

  void _apply(List<ConnectivityResult> results) {
    final next = results.any((r) => r != ConnectivityResult.none && r != ConnectivityResult.bluetooth);
    if (next == _hasNetwork) return;
    _hasNetwork = next;
    notifyListeners();
  }

  @visibleForTesting
  void setForTesting(bool? hasNetwork) {
    _hasNetwork = hasNetwork;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
