import 'package:flutter/foundation.dart';
import '../models/sos_alert.dart';

class FirebaseService {
  FirebaseService();

  Future<void> uploadSosAlert(SosAlert alert) async {
    try {
      debugPrint('Firebase upload: ${alert.toJson()}');
    } catch (e) {
      debugPrint('Firebase error: $e');
    }
  }
}