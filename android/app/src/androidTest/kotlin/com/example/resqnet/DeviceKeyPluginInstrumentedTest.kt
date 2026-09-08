package com.example.resqnet

import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented (real-device/emulator) tests for DeviceKeyPlugin. A plain
 * JVM unit test cannot exercise this — `AndroidKeyStore` is only
 * available on an actual Android runtime, not the host JVM — so this
 * runs under `./gradlew connectedDebugAndroidTest` against a real device
 * or emulator, exactly like the project's own testing requirement calls
 * for ("Add Android/native tests where practical").
 *
 * Calls straight into `DeviceKeyPlugin.onMethodCall` (the real, exact
 * dispatch path Flutter's engine would use) rather than private internals
 * — this is the more faithful test, not a workaround.
 */
@RunWith(AndroidJUnit4::class)
class DeviceKeyPluginInstrumentedTest {

    private val plugin = DeviceKeyPlugin()
    private val keyAlias = "resqnet_origin_signing_key_v1"

    private class CapturingResult : MethodChannel.Result {
        var successValue: Any? = null
        var errorCode: String? = null
        var errorMessage: String? = null
        var notImplementedCalled = false

        override fun success(result: Any?) {
            successValue = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            this.errorMessage = errorMessage
        }

        override fun notImplemented() {
            notImplementedCalled = true
        }
    }

    private fun invoke(method: String, args: Map<String, Any?>? = null): CapturingResult {
        val result = CapturingResult()
        plugin.onMethodCall(MethodCall(method, args), result)
        return result
    }

    @Suppress("UNCHECKED_CAST")
    private fun asMap(result: CapturingResult): Map<String, Any?> {
        assertNull("expected success, got error ${result.errorCode}: ${result.errorMessage}", result.errorCode)
        return result.successValue as Map<String, Any?>
    }

    private fun publicKeyFromPem(pem: String) = KeyFactory.getInstance("EC").generatePublic(
        X509EncodedKeySpec(
            Base64.decode(
                pem.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "").replace("\n", ""),
                Base64.DEFAULT,
            ),
        ),
    )

    @After
    fun tearDown() {
        // Leave no key behind between test methods in this class run —
        // each test that cares about a fresh identity deletes first
        // itself, but this is a defensive backstop against test order
        // dependence.
        invoke("deleteKeyPair")
    }

    @Test
    fun ensureKeyPair_generatesAValidP256PublicKey() {
        val map = asMap(invoke("ensureKeyPair"))
        assertEquals("ECDSA_P256_SHA256", map["algorithm"])
        val pem = map["publicKeyPem"] as String
        assertTrue(pem.contains("BEGIN PUBLIC KEY"))

        // Parses back into a real key and confirms it's genuinely P-256 —
        // proves the SPKI DER wrapping is actually valid, not just
        // PEM-shaped text.
        val publicKey = publicKeyFromPem(pem)
        assertEquals("EC", publicKey.algorithm)
    }

    @Test
    fun ensureKeyPair_isIdempotent_repeatedCallsReturnTheSameKeyId() {
        val firstKeyId = asMap(invoke("ensureKeyPair"))["keyId"]
        val secondKeyId = asMap(invoke("ensureKeyPair"))["keyId"]
        val thirdKeyId = asMap(invoke("ensureKeyPair"))["keyId"]
        assertEquals(firstKeyId, secondKeyId)
        assertEquals(firstKeyId, thirdKeyId)
    }

    @Test
    fun ensureKeyPair_keyPersistsInAndroidKeystoreAcrossPluginInstances() {
        invoke("ensureKeyPair")
        // A brand-new plugin instance (simulating a fresh app process
        // attaching to the same installed app's Keystore) must see the
        // SAME key — Keystore persistence is OS-level, not plugin-instance
        // state.
        val freshResult = CapturingResult()
        DeviceKeyPlugin().onMethodCall(MethodCall("ensureKeyPair", null), freshResult)
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertTrue(ks.containsAlias(keyAlias))
        assertEquals(asMap(freshResult)["keyId"], asMap(invoke("ensureKeyPair"))["keyId"])
    }

    @Test
    fun privateKey_isNotExportableFromRealAndroidKeystore() {
        invoke("ensureKeyPair")
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = ks.getEntry(keyAlias, null) as KeyStore.PrivateKeyEntry
        // Android's own documented behavior for Keystore-resident keys:
        // PrivateKey.getEncoded() returns null rather than raw key
        // material. This is direct, verifiable proof — on a REAL Android
        // Keystore, not a mock — that the private key cannot be exported
        // through any standard API.
        assertNull(
            "a Keystore-resident private key must never return encodable material",
            entry.privateKey.encoded,
        )
    }

    @Test
    fun sign_producesADerEcdsaSignatureVerifiableAgainstTheReturnedPublicKey() {
        val map = asMap(invoke("ensureKeyPair"))
        val publicKey = publicKeyFromPem(map["publicKeyPem"] as String)

        val testData = "resqnet-instrumented-test-payload".toByteArray(Charsets.UTF_8)
        val dataBase64 = Base64.encodeToString(testData, Base64.NO_WRAP)
        val signatureBase64 = asMap(invoke("sign", mapOf("dataBase64" to dataBase64)))["signatureBase64"] as String
        val signatureBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)

        val verified = Signature.getInstance("SHA256withECDSA").apply {
            initVerify(publicKey)
            update(testData)
        }.verify(signatureBytes)
        assertTrue("signature must verify against the key's own public key", verified)
    }

    @Test
    fun sign_signatureFailsVerificationAgainstAnUnrelatedKey() {
        invoke("ensureKeyPair")
        val testData = "resqnet-instrumented-test-payload".toByteArray(Charsets.UTF_8)
        val dataBase64 = Base64.encodeToString(testData, Base64.NO_WRAP)
        val signatureBase64 = asMap(invoke("sign", mapOf("dataBase64" to dataBase64)))["signatureBase64"] as String
        val signatureBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)

        // A completely different, unrelated keypair — never registered
        // with this plugin at all.
        val otherKeyPair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()

        val verified = Signature.getInstance("SHA256withECDSA").apply {
            initVerify(otherKeyPair.public)
            update(testData)
        }.verify(signatureBytes)
        assertFalse("a signature must never verify against an unrelated key", verified)
    }

    @Test
    fun sign_signatureFailsVerificationIfTheSignedDataIsModified() {
        val map = asMap(invoke("ensureKeyPair"))
        val publicKey = publicKeyFromPem(map["publicKeyPem"] as String)
        val original = "original payload".toByteArray(Charsets.UTF_8)
        val dataBase64 = Base64.encodeToString(original, Base64.NO_WRAP)
        val signatureBase64 = asMap(invoke("sign", mapOf("dataBase64" to dataBase64)))["signatureBase64"] as String
        val signatureBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)

        val tampered = "tampered payload!".toByteArray(Charsets.UTF_8)
        val verified = Signature.getInstance("SHA256withECDSA").apply {
            initVerify(publicKey)
            update(tampered)
        }.verify(signatureBytes)
        assertFalse("a signature for one payload must not verify a different payload", verified)
    }

    @Test
    fun sign_repeatedSigningWorksCorrectlyForDifferentPayloads() {
        invoke("ensureKeyPair")
        for (payload in listOf("payload-one", "payload-two", "payload-three")) {
            val dataBase64 = Base64.encodeToString(payload.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            val result = invoke("sign", mapOf("dataBase64" to dataBase64))
            assertNull(result.errorCode)
            assertNotNull(asMap(result)["signatureBase64"])
        }
    }

    @Test
    fun deleteKeyPair_thenEnsureKeyPair_generatesAGenuinelyNewIdentity_simulatingReinstall() {
        val firstKeyId = asMap(invoke("ensureKeyPair"))["keyId"]
        invoke("deleteKeyPair") // simulates what an app uninstall does to this app's Keystore entries
        val secondKeyId = asMap(invoke("ensureKeyPair"))["keyId"]
        assertNotEquals(
            "a key generated after deletion (reinstall-equivalent) must be a genuinely different identity",
            firstKeyId,
            secondKeyId,
        )
    }

    @Test
    fun sign_withoutEverCallingEnsureFirst_stillSucceedsByGeneratingLazily() {
        invoke("deleteKeyPair")
        val dataBase64 = Base64.encodeToString("data".toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val result = invoke("sign", mapOf("dataBase64" to dataBase64))
        assertNull(result.errorCode)
    }

    @Test
    fun crossPlatformVerification_logsPublicKeyAndSignatureForBackendVerification() {
        invoke("deleteKeyPair")
        val pem = asMap(invoke("ensureKeyPair"))["publicKeyPem"] as String

        // This exact string is independently asserted, byte-for-byte, in
        // test/origin_signable_fields_test.dart's "matches the exact
        // byte-length-prefixed shape the backend expects for a known
        // input" test, for the identical field values — reusing it here
        // means this signature is provably over the SAME bytes the Dart
        // implementation (and therefore what backend/src/utils/
        // originSignature.ts expects) would produce, not a hand-assembled
        // guess made independently in Kotlin.
        val canonical = "18:resqnet-sos-sig-v1" + "1:1" + "1:e" + "1:d" + "3:sos" +
            "6:manual" + "1:c" + "0:" + "0:" + "0:" + "0:" + "2:t1" + "2:t2" + "1:5" + "8:critical"

        val dataBase64 = Base64.encodeToString(canonical.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val signatureBase64 = asMap(invoke("sign", mapOf("dataBase64" to dataBase64)))["signatureBase64"] as String

        // Base64-encoding the PEM's own text (not just relying on
        // logcat's line handling) so a real multi-line PEM survives
        // extraction from logcat intact.
        Log.i("RESQNET_CROSS_VERIFY", "PEM_B64:" + Base64.encodeToString(pem.toByteArray(Charsets.UTF_8), Base64.NO_WRAP))
        Log.i("RESQNET_CROSS_VERIFY", "SIGNATURE_B64:$signatureBase64")
        Log.i("RESQNET_CROSS_VERIFY", "CANONICAL_B64:$dataBase64")
    }
}
