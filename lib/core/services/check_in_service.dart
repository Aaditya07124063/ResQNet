import 'dart:async';
import 'package:flutter/material.dart';

class CheckInService extends ChangeNotifier {
  Timer? _timer;
  DateTime? _deadline;
  Duration _interval = const Duration(hours: 1);
  bool _expired = false;

  bool get isActive => _deadline != null;
  bool get expired => _expired;
  Duration get interval => _interval;
  DateTime? get deadline => _deadline;

  Duration get remaining => _deadline == null
      ? Duration.zero
      : _deadline!.difference(DateTime.now());

  void start(Duration interval) {
    _interval = interval;
    _reset();
  }

  /// User taps "I'm OK" — timer restarts
  void checkIn() {
    if (isActive) _reset();
  }

  void _reset() {
    _expired = false;
    _deadline = DateTime.now().add(_interval);
    _timer?.cancel();
    _timer = Timer(_interval, () {
      _expired = true;
      notifyListeners();
    });
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    _expired = false;
    notifyListeners();
  }

  void acknowledgeExpiry() {
    _expired = false;
    notifyListeners();
  }
}