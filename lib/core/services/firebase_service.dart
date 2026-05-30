import 'package:flutter/foundation.dart';

class FirebaseService {
  FirebaseService();

  Future<void> uploadSosAlert(Map<String, dynamic> data) async {
    try {
      debugPrint('Firebase upload: $data');
    } catch (e) {
      debugPrint('Firebase error: $e');
    }
  }
}
