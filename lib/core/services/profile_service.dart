import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class ProfileService extends ChangeNotifier {
  String _name = '';
  String _bloodGroup = '';
  String _allergies = '';
  String _medications = '';
  String _emergencyContact = '';
  String _photoUrl = '';

  String get name => _name;
  String get bloodGroup => _bloodGroup;
  String get allergies => _allergies;
  String get medications => _medications;
  String get emergencyContact => _emergencyContact;
  String get photoUrl => _photoUrl;

  Future<void> loadProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('user_profiles')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 8));
      if (doc.exists) {
        final data = doc.data()!;
        _name = data['name'] ?? '';
        _bloodGroup = data['bloodGroup'] ?? '';
        _allergies = data['allergies'] ?? '';
        _medications = data['medications'] ?? '';
        _emergencyContact = data['emergencyContact'] ?? '';
        _photoUrl = data['photoUrl'] ?? '';
        notifyListeners();
      }
    } catch (e) {
      debugPrint('ProfileService load error: $e');
    }
  }
}