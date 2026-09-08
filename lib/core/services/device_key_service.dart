import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../network/api_client.dart';

/// Everything POST /api/v1/devices/keys (backend/src/routes/deviceRoutes.ts,
/// Phase 1) needs, plus the app-level `deviceId` — which is NOT the same
/// concept as the Keystore/Secure Enclave key alias (see
/// DeviceKeyPlugin.kt's own doc comment on why those are kept separate).
class DeviceKeyRegistrationMaterial {
  final String deviceId;
  final String keyId;
  final String publicKeyPem;
  final String algorithm;
  final bool isStrongBox;
  final bool isHardwareBacked;

  const DeviceKeyRegistrationMaterial({
    required this.deviceId,
    required this.keyId,
    required this.publicKeyPem,
    required this.algorithm,
    required this.isStrongBox,
    required this.isHardwareBacked,
  });
}

/// Thrown when this device genuinely cannot provide a cryptographic
/// origin-signing capability right now (no native module on this
/// platform yet, no Keystore provider, key generation failed for a
/// reason that isn't the expected StrongBox-unavailable fallback, etc.).
/// Callers must NEVER treat catching this as "try again with a fake
/// signature" — the correct response is to proceed without one, which
/// the backend's Phase 1 design already accounts for
/// ('unverified_unregistered' — see docs on origin_verification_state).
class DeviceKeyUnavailableException implements Exception {
  final String message;
  const DeviceKeyUnavailableException(this.message);
  @override
  String toString() => 'DeviceKeyUnavailableException: $message';
}

/// ResQNet's cryptographic device identity — the Dart-side half of the
/// origin-authentication architecture. The backend verification side
/// lives in backend/src/{utils/originSignature.ts,
/// services/deviceKeyService.ts} (Phase 1); the Android native signing
/// side lives in DeviceKeyPlugin.kt (Phase 2, this change); an iOS
/// native side (Secure Enclave/Keychain) is Phase 3, not yet built.
///
/// The private key never reaches this class, or any Dart code — every
/// method here returns only public material (a public key, a signature)
/// or nothing. Every code path that talks to the native key module goes
/// through this one class; nothing else in the app should invoke the
/// `com.resqnet.devicekey/methods` channel directly.
///
/// `deviceId` is a random UUID generated once per app install and
/// persisted in flutter_secure_storage alongside `keyId` — both
/// non-secret metadata (a UUID and a public key's own fingerprint are
/// not credentials, unlike the JWT/refresh tokens TokenStorage holds the
/// same way). Neither is derived from IMEI, MAC address, phone number,
/// or an advertising id, and neither is the same value as `userId` (the
/// backend account identity) or a push token (the separate `devices`
/// table) — see the architecture's explicit device-identity-separation
/// requirement. Uninstalling the app deletes both the Keystore-resident
/// key (an OS guarantee, not something this class manages) and this
/// secure-storage-resident deviceId/keyId — a reinstall therefore always
/// starts a genuinely new device identity, not a resurrected old one.
class DeviceKeyService {
  DeviceKeyService._();
  static final DeviceKeyService instance = DeviceKeyService._();

  static const MethodChannel _channel = MethodChannel('com.resqnet.devicekey/methods');
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const _deviceIdKey = 'resqnet_device_id_v1';
  static const _keyIdKey = 'resqnet_device_key_id_v1';
  static const _registeredKeyIdKey = 'resqnet_device_key_registered_v1';

  DeviceKeyRegistrationMaterial? _cached;

  /// Generates the local signing keypair if one doesn't already exist —
  /// idempotent, safe to call repeatedly (both here and natively: the
  /// native side checks Keystore for an existing alias before
  /// generating). Throws [DeviceKeyUnavailableException] if this device
  /// genuinely cannot provide the capability (including "no native
  /// implementation registered for this platform at all" — e.g. iOS
  /// before Phase 3, or web/desktop — surfaced via the platform channel's
  /// own [MissingPluginException] rather than a separate hardcoded
  /// platform check, so this stays correct as more platforms gain native
  /// support without needing to be updated here); never fabricates
  /// success.
  Future<DeviceKeyRegistrationMaterial> ensureKeyPair() async {
    final cached = _cached;
    if (cached != null) return cached; // avoid a redundant platform-channel round trip within one session

    final deviceId = await _ensureDeviceId();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('ensureKeyPair');
      if (result == null) {
        throw const DeviceKeyUnavailableException('Native key module returned no result');
      }
      final material = DeviceKeyRegistrationMaterial(
        deviceId: deviceId,
        keyId: result['keyId'] as String,
        publicKeyPem: result['publicKeyPem'] as String,
        algorithm: result['algorithm'] as String,
        isStrongBox: result['isStrongBox'] as bool? ?? false,
        isHardwareBacked: result['isHardwareBacked'] as bool? ?? false,
      );
      _cached = material;
      await _secureStorage.write(key: _keyIdKey, value: material.keyId);
      return material;
    } on PlatformException catch (e) {
      throw DeviceKeyUnavailableException(e.message ?? e.code);
    } on MissingPluginException {
      throw const DeviceKeyUnavailableException('Native device-key plugin is not registered');
    }
  }

  /// The exact material POST /api/v1/devices/keys needs. Calls
  /// [ensureKeyPair] first (idempotent, safe to call again) — a separate
  /// method name for readability at call sites, not a different
  /// operation.
  Future<DeviceKeyRegistrationMaterial> getPublicKeyForRegistration() => ensureKeyPair();

  /// Signs [canonicalString] (produced by, e.g.,
  /// core/utils/origin_signable_fields.dart's `buildSignableString` — this
  /// method does not know or care what the string represents, it only
  /// signs the exact UTF-8 bytes of whatever it's given) and returns a
  /// base64, DER-encoded ECDSA-P256-SHA256 signature. Only the signature
  /// crosses back from native code — never anything about the private
  /// key itself.
  Future<String> signCanonicalString(String canonicalString) async {
    await ensureKeyPair(); // idempotent — guarantees a key exists first
    final dataBase64 = base64Encode(utf8.encode(canonicalString));
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('sign', {
        'dataBase64': dataBase64,
      });
      final signature = result?['signatureBase64'] as String?;
      if (signature == null) {
        throw const DeviceKeyUnavailableException('Native signing returned no signature');
      }
      return signature;
    } on PlatformException catch (e) {
      throw DeviceKeyUnavailableException(e.message ?? e.code);
    }
  }

  /// Registers the current public key with the backend if it hasn't been
  /// successfully registered yet for this exact keyId. Intended to be
  /// called from the same post-login, online initialization path as
  /// NotificationService's FCM token registration (see home_screen.dart)
  /// — so an ordinary user normally already has a registered key before
  /// they ever go offline.
  ///
  /// Best-effort and deliberately conservative on failure: never deletes
  /// or regenerates the local key (it is the device's identity, not a
  /// disposable value — see class doc comment), never retries in a
  /// tight loop. Success is only recorded locally after the backend
  /// actually confirms it, so the next call to this method (the next
  /// app open/login) retries naturally — no separate retry-queue
  /// machinery needed, matching this codebase's existing pattern for
  /// best-effort post-login registration (NotificationService's own FCM
  /// token save).
  Future<bool> registerWithBackendIfNeeded() async {
    final DeviceKeyRegistrationMaterial material;
    try {
      material = await ensureKeyPair();
    } on DeviceKeyUnavailableException catch (e) {
      debugPrint('Device key unavailable, cannot register: $e');
      return false;
    }

    final alreadyRegisteredKeyId = await _secureStorage.read(key: _registeredKeyIdKey);
    if (alreadyRegisteredKeyId == material.keyId) {
      return true; // nothing changed since the last successful registration
    }

    try {
      await ApiClient.instance.post(
        '/devices/keys',
        auth: true,
        body: {
          'deviceId': material.deviceId,
          'keyId': material.keyId,
          'publicKey': material.publicKeyPem,
          'algorithm': material.algorithm,
        },
      );
      await _secureStorage.write(key: _registeredKeyIdKey, value: material.keyId);
      return true;
    } catch (e) {
      debugPrint('Device key backend registration failed (will retry later): $e');
      return false;
    }
  }

  Future<String> _ensureDeviceId() async {
    final existing = await _secureStorage.read(key: _deviceIdKey);
    if (existing != null) return existing;
    final generated = const Uuid().v4();
    await _secureStorage.write(key: _deviceIdKey, value: generated);
    return generated;
  }

  @visibleForTesting
  void resetCacheForTests() {
    _cached = null;
  }
}
