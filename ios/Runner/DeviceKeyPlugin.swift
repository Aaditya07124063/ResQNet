import Flutter
import Foundation
import Security
import CryptoKit

/// Native iOS half of ResQNet's cryptographic device identity — implements
/// the EXACT same MethodChannel contract as Android's DeviceKeyPlugin.kt
/// (channel `com.resqnet.devicekey/methods`, methods `ensureKeyPair`/
/// `sign`/`deleteKeyPair`) so `lib/core/services/device_key_service.dart`
/// needs no platform-specific code at all — it was written generically
/// against this shared contract from Phase 2.
///
/// The backend verification side (backend/src/utils/originSignature.ts,
/// Phase 1, unmodified) is the source of truth this plugin must produce
/// compatible material for: an ECDSA P-256 / SHA-256 signature and an
/// SPKI PEM public key.
///
/// Hardware guarantee, stated precisely (not overclaimed): when the
/// Secure Enclave is available, the private key is generated INSIDE it
/// (`kSecAttrTokenIDSecureEnclave`) and is non-exportable as an OS/
/// hardware guarantee — `SecKeyCopyExternalRepresentation` on a Secure
/// Enclave private key fails by design, there is no API that returns its
/// raw bytes. When the Secure Enclave is unavailable (the iOS Simulator
/// has none; some very old devices lack one), this falls back to a
/// Keychain-only software key. That fallback key is NOT hardware-isolated
/// the same way — the OS does not prevent a caller with the right
/// entitlements from reading it as raw bytes. This plugin closes that gap
/// itself: it never calls `SecKeyCopyExternalRepresentation` on a PRIVATE
/// key, on either path, only ever on the PUBLIC key — so from this app's
/// own code, the private key is never extracted regardless of which
/// backing store holds it, even though the STRENGTH of that guarantee
/// differs between the two paths. This distinction is intentionally not
/// blurred anywhere in this file's naming or comments.
public class DeviceKeyPlugin: NSObject, FlutterPlugin {
    private static let channelName = "com.resqnet.devicekey/methods"
    private static let applicationTag = "com.resqnet.devicekey.origin_signing_key_v1".data(using: .utf8)!

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = DeviceKeyPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ensureKeyPair":
            do {
                result(try ensureKeyPair())
            } catch let error as KeyCapabilityError {
                result(FlutterError(code: "KEY_UNAVAILABLE", message: error.message, details: nil))
            } catch {
                result(FlutterError(code: "NATIVE_ERROR", message: "\(error)", details: nil))
            }
        case "sign":
            guard let args = call.arguments as? [String: Any], let dataBase64 = args["dataBase64"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "dataBase64 is required", details: nil))
                return
            }
            do {
                result(try sign(dataBase64: dataBase64))
            } catch let error as KeyCapabilityError {
                result(FlutterError(code: "KEY_UNAVAILABLE", message: error.message, details: nil))
            } catch {
                result(FlutterError(code: "NATIVE_ERROR", message: "\(error)", details: nil))
            }
        case "deleteKeyPair":
            deleteKeyPair()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Thrown only when this device genuinely cannot provide the
    /// requested key capability — never thrown merely because the Secure
    /// Enclave specifically is unavailable (that path falls back
    /// silently, see generateKeyPair()).
    private struct KeyCapabilityError: Error {
        let message: String
    }

    private func ensureKeyPair() throws -> [String: Any] {
        if let existingPrivateKey = try findExistingPrivateKey() {
            return try publicKeyInfo(for: existingPrivateKey)
        }
        let newKey = try generateKeyPair()
        return try publicKeyInfo(for: newKey)
    }

    /// Generates the signing keypair, preferring the Secure Enclave.
    ///
    /// `.privateKeyUsage` alone (no `.biometryAny`/`.devicePasscode` flag)
    /// means this key can be used to sign WITHOUT a biometric/passcode
    /// prompt — the iOS equivalent of Android's
    /// `setUserAuthenticationRequired(false)`, and for the identical
    /// reason: an SOS must be signable from a locked phone's emergency
    /// path. Security tradeoff, stated plainly (mirrors DeviceKeyPlugin.kt's
    /// own documentation of the same tradeoff): any code running as this
    /// app's own process can request a signature without re-proving the
    /// user's presence at sign time. This does not weaken the Secure
    /// Enclave's separate, unconditional non-export guarantee.
    ///
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not
    /// `.whenUnlocked`) — chosen specifically so signing still works while
    /// the phone is CURRENTLY locked (only requires having been unlocked
    /// at least once since the last reboot, true for virtually any phone
    /// in active use), matching the "signable from a locked phone"
    /// requirement. `ThisDeviceOnly` (not the non-"ThisDeviceOnly" variant)
    /// excludes the key from iCloud Keychain sync/backup — required for
    /// Secure Enclave keys by the OS itself, and applied to the software
    /// fallback here too for the identical reason: this key is a device
    /// identity, not something that should silently reappear on a
    /// different device via iCloud restore.
    private func generateKeyPair() throws -> SecKey {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            nil
        ) else {
            throw KeyCapabilityError(message: "Could not create an access control policy for the signing key")
        }

        let secureEnclaveAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.applicationTag,
                kSecAttrAccessControl as String: access,
            ],
        ]

        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateRandomKey(secureEnclaveAttributes as CFDictionary, &error) {
            return key
        }
        // Secure Enclave unavailable (Simulator, or hardware without one) —
        // an EXPECTED, documented fallback, not an error condition. Falls
        // back to a Keychain-resident (non-Secure-Enclave) software key,
        // same curve/size/access-control policy, minus the
        // kSecAttrTokenID request.
        let softwareAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.applicationTag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        var fallbackError: Unmanaged<CFError>?
        if let key = SecKeyCreateRandomKey(softwareAttributes as CFDictionary, &fallbackError) {
            return key
        }
        let underlying = fallbackError?.takeRetainedValue().localizedDescription ?? "unknown error"
        throw KeyCapabilityError(message: "This device cannot generate a signing key even without the Secure Enclave: \(underlying)")
    }

    private func findExistingPrivateKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.applicationTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item {
            // swiftlint:disable:next force_cast
            return (key as! SecKey)
        }
        if status == errSecItemNotFound {
            return nil
        }
        throw KeyCapabilityError(message: "Keychain query failed with status \(status)")
    }

    private func deleteKeyPair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.applicationTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Builds the registration-material map, including deriving the
    /// SPKI-PEM form of the public key — see `spkiPem(fromRawEcPoint:)`'s
    /// own doc comment for why this conversion is needed at all on iOS
    /// but not Android.
    private func publicKeyInfo(for privateKey: SecKey) throws -> [String: Any] {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeyCapabilityError(message: "Could not derive the public key")
        }
        var error: Unmanaged<CFError>?
        // SecKeyCopyExternalRepresentation is called on the PUBLIC key
        // only — see this file's own top-level doc comment on why the
        // private key is never passed to this function anywhere in this
        // plugin.
        guard let rawPointData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let underlying = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw KeyCapabilityError(message: "Could not export the public key: \(underlying)")
        }

        let spkiDer = Self.spkiDer(fromRawEcPoint: rawPointData)
        let pem = Self.toPem(der: spkiDer)
        let keyId = Self.fingerprint(spkiDer: spkiDer)

        let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any]
        let tokenID = attributes?[kSecAttrTokenID as String] as? String
        let isSecureEnclave = tokenID == (kSecAttrTokenIDSecureEnclave as String)

        return [
            "keyId": keyId,
            "publicKeyPem": pem,
            "algorithm": "ECDSA_P256_SHA256",
            "isStrongBox": false, // StrongBox is an Android-specific concept; never true on iOS.
            "isHardwareBacked": isSecureEnclave,
        ]
    }

    private func sign(dataBase64: String) throws -> [String: Any] {
        guard let data = Data(base64Encoded: dataBase64) else {
            throw KeyCapabilityError(message: "dataBase64 was not valid base64")
        }
        let privateKey: SecKey
        if let existing = try findExistingPrivateKey() {
            privateKey = existing
        } else {
            privateKey = try generateKeyPair()
        }

        var error: Unmanaged<CFError>?
        // .ecdsaSignatureMessageX962SHA256 takes the RAW message (not a
        // pre-computed digest) and internally hashes with SHA-256 before
        // signing — exactly one hash-then-sign step, matching Android's
        // "SHA256withECDSA" and Node's crypto.sign('sha256', ...) for EC
        // keys. The output is DER-encoded (ASN.1 SEQUENCE of two
        // INTEGERs, "X9.62" in Apple's naming) — the same format Android
        // and Node produce by default, so no signature-format conversion
        // is needed anywhere in this pipeline.
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            let underlying = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw KeyCapabilityError(message: "Signing failed: \(underlying)")
        }

        return ["signatureBase64": signature.base64EncodedString()]
    }

    /// iOS's Security framework exports EC public keys in raw X9.63 form
    /// (`0x04 || X || Y`, 65 bytes for P-256) via
    /// `SecKeyCopyExternalRepresentation` — NOT the X.509
    /// SubjectPublicKeyInfo (SPKI) DER format Android's
    /// `PublicKey.getEncoded()` returns natively and that
    /// backend/src/utils/originSignature.ts's `assertValidP256PublicKey`
    /// (via Node's `crypto.createPublicKey`) expects. This prepends the
    /// fixed, standard 26-byte ASN.1 header for "EC public key, P-256
    /// curve" — a well-known, publicly documented byte sequence (the DER
    /// encoding of the algorithm identifier for id-ecPublicKey +
    /// prime256v1), not an invented format — to produce a valid SPKI DER
    /// identical in structure to what Android already emits natively.
    private static func spkiDer(fromRawEcPoint rawPoint: Data) -> Data {
        let p256SpkiHeader: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ]
        return Data(p256SpkiHeader) + rawPoint
    }

    private static func toPem(der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN PUBLIC KEY-----\n" + lines.joined(separator: "\n") + "\n-----END PUBLIC KEY-----\n"
    }

    /// SHA-256 fingerprint of the SPKI DER bytes, base64url without
    /// padding — identical algorithm to DeviceKeyPlugin.kt's
    /// `fingerprint()`, so a keyId means the same thing regardless of
    /// which platform generated it.
    private static func fingerprint(spkiDer: Data) -> String {
        let digest = SHA256.hash(data: spkiDer)
        let base64 = Data(digest).base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
