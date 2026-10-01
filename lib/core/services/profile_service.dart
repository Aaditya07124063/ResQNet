import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import '../utils/medical_summary.dart';

/// Holds the user's profile — cached locally (SharedPreferences) so it's
/// available instantly and offline, and synced with the ResQNet backend
/// (`GET/PUT /api/v1/profile`, Phase 5) in the background so it's shared
/// across devices.
///
/// Phase 20 (Firebase removal): replaces the previous Firestore
/// `user_profiles/{uid}` sync. **Known gaps, not invented around**:
/// - `name`/`phone`/`email`/`photoUrl` have no home in the backend's
///   `user_profiles` table (that table is emergency-relevant fields only
///   — father's name, blood group, allergies, etc.; identity fields like
///   display name/phone/email live on `users`, populated from
///   Google/phone sign-in itself, with no update endpoint exposed). These
///   four fields stay LOCAL-CACHE-ONLY here — never synced, same as
///   before this phase for anyone not signed in, but now true for
///   everyone regardless of sign-in state. See docs/DONE.md's Phase 20
///   entry for what a real fix would require (a `users` display-name
///   update endpoint — not built anywhere, not invented here).
/// - Unlike Firestore's own SDK, the plain HTTP `ApiClient` does not
///   queue a write made while offline and retry it automatically —
///   see trusted_contacts_service.dart's identical note.
/// - `photoUrl` is now a short-lived (10-minute) MinIO signed URL
///   (Phase 6), not a permanent Firebase Storage URL — call
///   [refreshPhotoUrl] to get a fresh one rather than trusting a cached
///   value to still work.
class ProfileService extends ChangeNotifier {
  /// Local copy of the profile, including the medical details the user
  /// chose to save. Removed on sign-out (AuthService).
  static const storageKey = 'profile_cache';

  String _name = '';
  String _fatherName = '';
  String _age = '';
  String _address = '';
  String _bloodGroup = '';
  String _allergies = '';
  String _medications = '';
  String _emergencyContact = '';
  String _photoUrl = '';
  String _country = '';
  String _state = '';
  String _city = '';

  String get name => _name;
  String get fatherName => _fatherName;
  String get age => _age;
  String get address => _address;
  // --- Medical information in automatic SOS (explicit opt-in) ---

  /// Device-local preference, separate from the synced profile. OFF unless
  /// the user turns it on; never inferred from having medical details.
  static const includeMedicalInAutoSosKey = 'resqnet_medical_in_auto_sos_v1';
  bool _includeMedicalInAutoSos = false;
  bool get includeMedicalInAutoSos => _includeMedicalInAutoSos;

  /// Reads the preference. Anything other than a stored `true` (missing,
  /// wrong type, storage error) means OFF.
  Future<void> loadMedicalSharingPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _includeMedicalInAutoSos = prefs.get(includeMedicalInAutoSosKey) == true;
    } catch (_) {
      _includeMedicalInAutoSos = false;
    }
    notifyListeners();
  }

  Future<void> setIncludeMedicalInAutoSos(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(includeMedicalInAutoSosKey, value);
    _includeMedicalInAutoSos = value;
    notifyListeners();
  }

  /// What an automatic (crash/earthquake) SOS may add to its signed message:
  /// blood group and allergies, only when the user opted in; otherwise ''.
  /// Medications are never included.
  String get automaticSosMedicalSummary =>
      _includeMedicalInAutoSos ? medicalSummary(_bloodGroup, _allergies) : '';

  String get bloodGroup => _bloodGroup;
  String get allergies => _allergies;
  String get medications => _medications;
  String get emergencyContact => _emergencyContact;
  String get photoUrl => _photoUrl;
  String get country => _country;
  String get state => _state;
  String get city => _city;

  Map<String, dynamic> toJson() => {
        'name': _name,
        'fatherName': _fatherName,
        'age': _age,
        'address': _address,
        'bloodGroup': _bloodGroup,
        'allergies': _allergies,
        'medications': _medications,
        'emergencyContact': _emergencyContact,
        'photoUrl': _photoUrl,
        'country': _country,
        'state': _state,
        'city': _city,
      };

  void _applyData(Map<String, dynamic> data) {
    _name = data['name'] ?? '';
    _fatherName = data['fatherName'] ?? '';
    _age = data['age'] ?? '';
    _address = data['address'] ?? '';
    _bloodGroup = data['bloodGroup'] ?? '';
    _allergies = data['allergies'] ?? '';
    _medications = data['medications'] ?? '';
    _emergencyContact = data['emergencyContact'] ?? '';
    _photoUrl = data['photoUrl'] ?? '';
    _country = data['country'] ?? '';
    _state = data['state'] ?? '';
    _city = data['city'] ?? '';
  }

  /// Merges only the fields the backend's `user_profiles` actually has —
  /// `name`/`phone`/`email`/`photoUrl` are left exactly as already cached
  /// (see class doc comment on why those have no backend home).
  void _applyBackendData(Map<String, dynamic> profile) {
    _fatherName = profile['fatherName'] as String? ?? _fatherName;
    _age = profile['age'] != null ? (profile['age'] as num).toInt().toString() : _age;
    _address = profile['address'] as String? ?? _address;
    _bloodGroup = profile['bloodGroup'] as String? ?? _bloodGroup;
    _allergies = profile['allergies'] as String? ?? _allergies;
    _medications = profile['medications'] as String? ?? _medications;
    _emergencyContact = profile['emergencyContact'] as String? ?? _emergencyContact;
    _country = profile['country'] as String? ?? _country;
    _state = profile['state'] as String? ?? _state;
    _city = profile['city'] as String? ?? _city;
  }

  /// Loads from the local cache only — instant, works with zero internet.
  Future<void> loadFromCache() async {
    await loadMedicalSharingPreference();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null) {
      _applyData(jsonDecode(raw) as Map<String, dynamic>);
      notifyListeners();
    }
  }

  /// Best-effort refresh from the backend — no-ops quietly if offline or
  /// not backend-authenticated yet (the cached data from [loadFromCache]
  /// just stays as-is).
  Future<void> syncFromCloud() async {
    try {
      final response = await ApiClient.instance
          .get('/profile', auth: true)
          .timeout(const Duration(seconds: 8));
      final profile = response['profile'] as Map<String, dynamic>?;
      if (profile != null) {
        _applyBackendData(profile);
        notifyListeners();
        await _persistLocal();
      }
      await refreshPhotoUrl();
    } catch (e) {
      debugPrint('ProfileService cloud sync error: $e');
    }
  }

  /// Fetches a fresh signed URL for the profile picture (Phase 6 MinIO —
  /// `GET /api/v1/profile/image`), since a cached one expires after 10
  /// minutes. Safe to call even when no picture has ever been set (404
  /// is treated as "no photo", not an error).
  Future<void> refreshPhotoUrl() async {
    try {
      final response = await ApiClient.instance.get('/profile/image', auth: true);
      final url = response['url'] as String?;
      if (url != null && url != _photoUrl) {
        _photoUrl = url;
        notifyListeners();
        await _persistLocal();
      }
    } on ApiException catch (e) {
      if (!e.isNetworkError && e.statusCode != 404) {
        debugPrint('ProfileService photo URL refresh error: $e');
      }
    }
  }

  /// Loads cache first (instant), then refreshes from the backend if
  /// reachable. Use this when you just need the data and don't need to
  /// show cached results before the round-trip finishes.
  Future<void> loadProfile() async {
    await loadFromCache();
    await syncFromCloud();
  }

  /// Saves locally immediately (so it's available offline right away) and
  /// pushes the backend-known fields to `PUT /api/v1/profile` in the
  /// background.
  Future<void> saveProfile(Map<String, dynamic> data) async {
    _applyData(data);
    notifyListeners();
    await _persistLocal();

    try {
      await ApiClient.instance.put(
        '/profile',
        auth: true,
        body: {
          'fatherName': _fatherName.isEmpty ? null : _fatherName,
          'age': _age.isEmpty ? null : int.tryParse(_age),
          'address': _address.isEmpty ? null : _address,
          'bloodGroup': _bloodGroup.isEmpty ? null : _bloodGroup,
          'allergies': _allergies.isEmpty ? null : _allergies,
          'medications': _medications.isEmpty ? null : _medications,
          'emergencyContact': _emergencyContact.isEmpty ? null : _emergencyContact,
          'country': _country.isEmpty ? null : _country,
          'state': _state.isEmpty ? null : _state,
          'city': _city.isEmpty ? null : _city,
        },
      );
    } on ApiException catch (e) {
      debugPrint('ProfileService save error: $e');
    }
  }

  Future<void> _persistLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(toJson()));
  }

  /// Forgets the signed-in user's profile on this device (memory and disk).
  Future<void> clearLocal() async {
    _name = '';
    _fatherName = '';
    _age = '';
    _address = '';
    _bloodGroup = '';
    _allergies = '';
    _medications = '';
    _emergencyContact = '';
    _photoUrl = '';
    _country = '';
    _state = '';
    _city = '';
    // The medical-sharing opt-in belongs to the signed-out person too.
    _includeMedicalInAutoSos = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
    await prefs.remove(includeMedicalInAutoSosKey);
    notifyListeners();
  }
}
