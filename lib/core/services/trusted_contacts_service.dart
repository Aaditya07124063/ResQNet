import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';

class TrustedContact {
  final String id;
  final String name;
  final String relation;
  final String phone;
  /// The backend's `trusted_contacts.contact_user_id` — set only when this
  /// contact has also been matched to a ResQNet account (backend-side
  /// linkage, never guessed on-device). Non-null is what makes "message
  /// this contact through ResQNet" possible at all — see
  /// emergency_contacts_screen.dart's use of it. Always null for a
  /// locally-cached-only contact (no `fromBackendJson` round-trip yet).
  final String? contactUserId;

  TrustedContact({
    required this.id,
    required this.name,
    required this.relation,
    required this.phone,
    this.contactUserId,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'relation': relation, 'phone': phone, 'contactUserId': contactUserId};

  factory TrustedContact.fromJson(Map<String, dynamic> json) => TrustedContact(
        id: json['id'],
        name: json['name'] ?? '',
        relation: json['relation'] ?? '',
        phone: json['phone'] ?? '',
        contactUserId: json['contactUserId'] as String?,
      );

  /// Maps the backend's `TrustedContact` shape (`profileRoutes.ts` /
  /// `trustedContactsService.ts`) — `phoneNumber`/`relationship`, not
  /// `phone`/`relation` — to this local model.
  factory TrustedContact.fromBackendJson(Map<String, dynamic> json) => TrustedContact(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        relation: json['relationship'] as String? ?? '',
        phone: json['phoneNumber'] as String? ?? '',
        contactUserId: json['contactUserId'] as String?,
      );
}

/// Personal relatives/parents the user wants alerted the moment they send
/// an SOS — distinct from [EmergencyContactsService]'s national
/// police/fire/ambulance hotlines.
///
/// Cached locally (SharedPreferences) so the list — and therefore the SMS
/// fallback in [SosDispatchService] — is available with zero internet, and
/// synced with the ResQNet backend (`GET/POST/PUT/DELETE
/// /api/v1/profile/trusted-contacts`, Phase 5) when online so it survives
/// a reinstall/new device.
///
/// Phase 20 (Firebase removal): replaces the previous Firestore
/// subcollection sync. **Known limitation, not invented around**: unlike
/// Firestore's own SDK, the plain HTTP `ApiClient` does not queue a
/// write made while offline and retry it automatically once connectivity
/// returns — a write attempted while offline (or before backend Google/
/// phone sign-in has completed) is simply not synced until the next
/// explicit [load] call succeeds. The local cache still has the data
/// either way, so nothing is ever lost from the user's own device, but
/// cross-device sync of an offline-made change isn't automatic the way
/// it was under Firestore.
class TrustedContactsService extends ChangeNotifier {
  static const _storageKey = 'trusted_contacts';
  List<TrustedContact> _contacts = [];

  List<TrustedContact> get contacts => List.unmodifiable(_contacts);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      _contacts =
          (jsonDecode(raw) as List).map((e) => TrustedContact.fromJson(e)).toList();
      notifyListeners();
    }
    await _syncFromCloud();
  }

  Future<void> _syncFromCloud() async {
    try {
      final response = await ApiClient.instance
          .get('/profile/trusted-contacts', auth: true)
          .timeout(const Duration(seconds: 8));
      final list = (response['contacts'] as List).cast<Map<String, dynamic>>();
      _contacts = list.map(TrustedContact.fromBackendJson).toList();
      notifyListeners();
      await _persistLocal();
    } catch (e) {
      // Not backend-authenticated yet, offline, or a real failure — the
      // cached list from [load] above just stays as-is, same graceful
      // degradation the Firestore version had.
      debugPrint('Trusted contacts cloud sync error: $e');
    }
  }

  Future<void> addContact({
    required String name,
    required String relation,
    required String phone,
  }) async {
    var contact =
        TrustedContact(id: const Uuid().v4(), name: name, relation: relation, phone: phone);
    _contacts.add(contact);
    notifyListeners();
    await _persistLocal();

    try {
      final response = await ApiClient.instance.post(
        '/profile/trusted-contacts',
        auth: true,
        body: {'name': name, 'phoneNumber': phone, 'relationship': relation},
      );
      // The backend assigns its own id — replace the optimistic local
      // entry with the real one so a later update/delete this session
      // addresses the row that actually exists server-side.
      final synced = TrustedContact.fromBackendJson(response['contact'] as Map<String, dynamic>);
      final index = _contacts.indexWhere((c) => c.id == contact.id);
      if (index != -1) {
        _contacts[index] = synced;
        contact = synced;
        notifyListeners();
        await _persistLocal();
      }
    } on ApiException catch (e) {
      debugPrint('Trusted contact save error: $e');
    }
  }

  Future<void> removeContact(String id) async {
    _contacts.removeWhere((c) => c.id == id);
    notifyListeners();
    await _persistLocal();

    try {
      await ApiClient.instance.delete('/profile/trusted-contacts/$id', auth: true);
    } on ApiException catch (e) {
      // Including a 404 for a contact that was only ever added locally
      // (offline) and never actually synced — nothing to delete
      // server-side, which is fine.
      debugPrint('Trusted contact delete error: $e');
    }
  }

  Future<void> _persistLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(_contacts.map((c) => c.toJson()).toList()),
    );
  }
}
