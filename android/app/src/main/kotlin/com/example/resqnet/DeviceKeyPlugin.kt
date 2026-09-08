package com.example.resqnet

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * Native Android half of ResQNet's cryptographic device identity — the
 * origin-authentication architecture whose backend verification side
 * lives in backend/src/utils/originSignature.ts (Phase 1, already
 * implemented and tested). This plugin does NOT reimplement any part of
 * that verification logic; it only produces material the backend already
 * knows how to verify: an ECDSA P-256 / SHA-256 signature and an SPKI PEM
 * public key.
 *
 * Same MethodChannel name/method contract is intended to be implemented
 * again, identically, by an iOS plugin in Phase 3 (Secure Enclave/
 * Keychain) — device_key_service.dart talks to ONE channel, platform-
 * agnostic, rather than the split per-platform-implementation Dart file
 * pattern mesh_service.dart uses (that split exists there because
 * Android's mesh transport is a pub.dev package and iOS's is bespoke
 * native code; here NEITHER platform has a usable pub.dev package, so a
 * single shared contract both native sides implement is the simpler,
 * correct design).
 *
 * Hard security invariants this file exists to uphold:
 * - The private key is generated INSIDE Android Keystore and never
 *   leaves it. `KeyStore.PrivateKeyEntry.getPrivateKey()` returns an
 *   opaque handle usable only for sign/verify operations THIS process
 *   can request through the Keystore daemon — there is no API that
 *   returns raw private key bytes for a Keystore-resident key. Nothing
 *   in this file attempts to export, serialize, or transmit private key
 *   material — only the PUBLIC key and SIGNATURES ever cross the
 *   MethodChannel back to Dart.
 * - One fixed Keystore alias is used for the app's single active signing
 *   identity (see KEY_ALIAS) — deviceId (an app-level, Dart-generated
 *   UUID used for the backend's device_keys.device_id and mesh envelope
 *   identity) is intentionally NOT passed into this plugin at all: the
 *   Keystore alias and the app-level device identity are different
 *   concepts, and conflating them would give the OS Keystore alias
 *   naming pattern the same tracking-relevant status as the app-level id
 *   this architecture otherwise carefully keeps separate.
 */
class DeviceKeyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    companion object {
        private const val CHANNEL_NAME = "com.resqnet.devicekey/methods"
        private const val KEY_ALIAS = "resqnet_origin_signing_key_v1"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"

        // NIST P-256 — OpenSSL/Node calls this 'prime256v1', Java/Android
        // calls it 'secp256r1'; same curve, matching
        // backend/src/utils/originSignature.ts's assertValidP256PublicKey.
        private const val CURVE_NAME = "secp256r1"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "ensureKeyPair" -> result.success(ensureKeyPair())
                "sign" -> {
                    val dataBase64 = call.argument<String>("dataBase64")
                    if (dataBase64 == null) {
                        result.error("INVALID_ARGUMENT", "dataBase64 is required", null)
                        return
                    }
                    result.success(sign(dataBase64))
                }
                "deleteKeyPair" -> {
                    deleteKeyPair()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: KeyCapabilityException) {
            // A typed, honest failure — this device genuinely cannot
            // provide the requested key capability right now. Mapped by
            // device_key_service.dart to "treat this origin as unable to
            // sign", never faked as success (Phase 1's
            // 'unverified_unregistered' state exists for exactly this).
            result.error("KEY_UNAVAILABLE", e.message, null)
        } catch (e: Exception) {
            result.error("NATIVE_ERROR", e.message, null)
        }
    }

    /** Thrown only when the platform genuinely cannot provide the
     * requested key capability (no AndroidKeyStore provider, or key
     * generation/retrieval failed for a reason that isn't the expected
     * StrongBox-unavailable fallback). Never thrown merely because
     * StrongBox specifically is missing — that path falls back silently,
     * see generateKeyPair(). */
    private class KeyCapabilityException(message: String) : Exception(message)

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }

    private fun ensureKeyPair(): Map<String, Any?> {
        val ks = keyStore()
        if (!ks.containsAlias(KEY_ALIAS)) {
            generateKeyPair()
        }
        return publicKeyInfo(keyStore())
    }

    /**
     * Generates the signing keypair inside Android Keystore.
     *
     * StrongBox (a dedicated, tamper-resistant security chip, API 28+)
     * is requested first. If unavailable — no chip on this device, or an
     * API level that doesn't support it — Android throws
     * StrongBoxUnavailableException, which is caught here as an EXPECTED
     * outcome, not an error: generation is retried without StrongBox,
     * falling back to Keystore's normal (typically TEE-backed, though
     * that itself isn't guaranteed by any public API) key storage. This
     * fallback must never fail the emergency SOS flow merely because
     * StrongBox specifically is unavailable — requirement #9.
     *
     * Referencing StrongBoxUnavailableException (API 28) and
     * setIsStrongBoxBacked (API 28) in code that also runs on this
     * project's minSdk=24 is safe: the StrongBox branch is only ever
     * ENTERED when `Build.VERSION.SDK_INT >= P`, so on API 24-27 devices
     * this exception is never actually thrown or caught at runtime — and
     * modern ART's per-class (not eager whole-method) verification does
     * not require these API-28 symbols to resolve on an API-24 device
     * for unreached code paths. This is the same pattern used throughout
     * the Android ecosystem for API-gated features.
     *
     * setUserAuthenticationRequired(false) — DELIBERATE (see the
     * architecture plan's own "Android locked-phone requirement"
     * section): an SOS must be signable without a biometric/PIN prompt.
     * Security tradeoff, stated plainly: this key can be used to produce
     * a signature by any code running as THIS APP's own process,
     * without re-proving the user's presence via biometrics at sign
     * time. It does NOT weaken Keystore's separate, unconditional
     * non-export guarantee — the private key still cannot be extracted
     * by this process or any other, regardless of this setting. The
     * alternative (requiring authentication) would mean a locked phone,
     * or a phone whose biometric sensor is damaged/unavailable in an
     * emergency, could not sign an SOS at all — judged strictly worse
     * for the emergency use case this key exists to serve.
     */
    private fun generateKeyPair() {
        fun buildSpec(strongBox: Boolean): KeyGenParameterSpec {
            val builder = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec(CURVE_NAME))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                builder.setIsStrongBoxBacked(true)
            }
            return builder.build()
        }

        try {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE_PROVIDER)
            generator.initialize(buildSpec(strongBox = true))
            generator.generateKeyPair()
        } catch (e: StrongBoxUnavailableException) {
            try {
                val fallbackGenerator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE_PROVIDER)
                fallbackGenerator.initialize(buildSpec(strongBox = false))
                fallbackGenerator.generateKeyPair()
            } catch (fallbackError: Exception) {
                throw KeyCapabilityException(
                    "This device cannot generate a signing key even without StrongBox: ${fallbackError.message}",
                )
            }
        } catch (e: Exception) {
            throw KeyCapabilityException("This device cannot generate a signing key: ${e.message}")
        }
    }

    private fun publicKeyInfo(ks: KeyStore): Map<String, Any?> {
        val entry = ks.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw KeyCapabilityException("No signing key present after generation")
        val publicKey = entry.certificate.publicKey as ECPublicKey
        // X.509 SubjectPublicKeyInfo DER — this is what
        // java.security.PublicKey.getEncoded() already returns for an EC
        // key, and it is EXACTLY the format backend/src/utils/
        // originSignature.ts's assertValidP256PublicKey expects wrapped
        // in PEM (Node's crypto.createPublicKey parses SPKI PEM
        // directly) — no reformatting/conversion needed on this side.
        val spkiDer = publicKey.encoded
        val pem = toPem(spkiDer)
        val keyId = fingerprint(spkiDer)

        var isStrongBox = false
        var isHardwareBacked = false
        try {
            val factory = KeyFactory.getInstance(entry.privateKey.algorithm, KEYSTORE_PROVIDER)
            val keyInfo = factory.getKeySpec(entry.privateKey, KeyInfo::class.java)
            isHardwareBacked = keyInfo.isInsideSecureHardware
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                isStrongBox = keyInfo.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
            }
        } catch (e: Exception) {
            // Best-effort introspection only — classification failing
            // must never make an otherwise-usable key unavailable.
        }

        return mapOf(
            "keyId" to keyId,
            "publicKeyPem" to pem,
            "algorithm" to "ECDSA_P256_SHA256",
            "isStrongBox" to isStrongBox,
            "isHardwareBacked" to isHardwareBacked,
        )
    }

    private fun sign(dataBase64: String): Map<String, Any?> {
        val ks = keyStore()
        if (!ks.containsAlias(KEY_ALIAS)) {
            generateKeyPair()
        }
        val entry = ks.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw KeyCapabilityException("No signing key available")
        val data = Base64.decode(dataBase64, Base64.NO_WRAP)
        // "SHA256withECDSA" — a single hash-then-sign over the raw bytes
        // handed in, producing a DER-encoded ECDSA signature (ASN.1
        // SEQUENCE of two INTEGERs). This is exactly what
        // originSignature.ts's `crypto.verify('sha256', ..., {dsaEncoding:
        // 'der'}, ...)` expects — no signature-format conversion needed.
        // The canonical bytes being signed are built entirely in Dart
        // (mirroring originSignature.ts's buildSignableBytes) — this
        // plugin never constructs or interprets the SOS envelope itself,
        // it only signs whatever bytes it is handed.
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(entry.privateKey)
            update(data)
            sign()
        }
        return mapOf("signatureBase64" to Base64.encodeToString(signature, Base64.NO_WRAP))
    }

    private fun deleteKeyPair() {
        val ks = keyStore()
        if (ks.containsAlias(KEY_ALIAS)) {
            ks.deleteEntry(KEY_ALIAS)
        }
    }

    private fun toPem(der: ByteArray): String {
        val base64 = Base64.encodeToString(der, Base64.NO_WRAP)
        val lines = base64.chunked(64).joinToString("\n")
        return "-----BEGIN PUBLIC KEY-----\n$lines\n-----END PUBLIC KEY-----\n"
    }

    /** SHA-256 fingerprint of the SPKI DER bytes, base64url without
     * padding (43 chars) — comfortably inside device_keys.key_id's
     * VARCHAR(64). Deterministic and derivable by anyone from the public
     * key alone (not a secret), matching the backend's own key_id
     * concept exactly. */
    private fun fingerprint(spkiDer: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(spkiDer)
        return Base64.encodeToString(digest, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
    }
}
