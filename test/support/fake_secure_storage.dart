import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Installs an in-memory fake for `flutter_secure_storage`'s platform
/// channel, so `TokenStorage` (which uses the real package, unmodified)
/// works correctly under plain `flutter test` (no real platform attached,
/// so the genuine channel would otherwise throw MissingPluginException).
///
/// Channel name and method/argument shapes verified directly against the
/// installed package
/// (flutter_secure_storage_platform_interface-2.0.3/lib/src/method_channel_flutter_secure_storage.dart)
/// rather than assumed.
class FakeSecureStorage {
  FakeSecureStorage() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  final Map<String, String> _store = {};

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'write':
        _store[call.arguments['key'] as String] = call.arguments['value'] as String;
        return null;
      case 'read':
        return _store[call.arguments['key'] as String];
      case 'delete':
        _store.remove(call.arguments['key'] as String);
        return null;
      case 'deleteAll':
        _store.clear();
        return null;
      case 'containsKey':
        return _store.containsKey(call.arguments['key'] as String);
      case 'readAll':
        return Map<String, String>.from(_store);
      default:
        return null;
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
