import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mocks the native Android/iOS device-key plugin's MethodChannel. Method
/// name/argument/return shapes match DeviceKeyPlugin.kt/.swift exactly
/// (see their own doc comments) — this is the contract both native sides
/// implement identically.
class FakeDeviceKeyChannel {
  FakeDeviceKeyChannel({
    this.keyId = 'fake-key-id-fingerprint',
    this.publicKeyPem = '-----BEGIN PUBLIC KEY-----\nFAKEFAKEFAKE\n-----END PUBLIC KEY-----\n',
    this.signatureBase64 = 'ZmFrZS1zaWduYXR1cmU=',
    this.throwOnEnsure,
    this.throwOnSign,
  }) {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const _channel = MethodChannel('com.resqnet.devicekey/methods');

  String keyId;
  String publicKeyPem;
  String signatureBase64;
  PlatformException? throwOnEnsure;
  PlatformException? throwOnSign;

  final List<MethodCall> calls = [];
  int ensureKeyPairCallCount = 0;
  int signCallCount = 0;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'ensureKeyPair':
        ensureKeyPairCallCount++;
        if (throwOnEnsure != null) throw throwOnEnsure!;
        return {
          'keyId': keyId,
          'publicKeyPem': publicKeyPem,
          'algorithm': 'ECDSA_P256_SHA256',
          'isStrongBox': false,
          'isHardwareBacked': true,
        };
      case 'sign':
        signCallCount++;
        if (throwOnSign != null) throw throwOnSign!;
        return {'signatureBase64': signatureBase64};
      case 'deleteKeyPair':
        return null;
      default:
        throw MissingPluginException('not implemented in fake: ${call.method}');
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
