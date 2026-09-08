import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() {
    secureStorage = FakeSecureStorage();
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
    DeviceKeyService.instance.resetCacheForTests();
  });

  group('ensureKeyPair', () {
    test('returns material assembled from the native response', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      final material = await DeviceKeyService.instance.ensureKeyPair();

      expect(material.keyId, 'fake-key-id-fingerprint');
      expect(material.publicKeyPem, contains('BEGIN PUBLIC KEY'));
      expect(material.algorithm, 'ECDSA_P256_SHA256');
      expect(material.isHardwareBacked, true);
      expect(material.deviceId, isNotEmpty);
    });

    test('generates a deviceId once and persists it — a second, fresh service call reuses the same value', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      final first = await DeviceKeyService.instance.ensureKeyPair();
      DeviceKeyService.instance.resetCacheForTests(); // simulate "in-memory cache gone", storage persists
      final second = await DeviceKeyService.instance.ensureKeyPair();

      expect(second.deviceId, first.deviceId);
    });

    test('caches within a session — a second call does not re-invoke the native channel', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      await DeviceKeyService.instance.ensureKeyPair();
      await DeviceKeyService.instance.ensureKeyPair();

      expect(fake.ensureKeyPairCallCount, 1);
    });

    test('repeated calls after a cache reset remain idempotent — native always reports the same key', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      final results = <String>[];
      for (var i = 0; i < 3; i++) {
        DeviceKeyService.instance.resetCacheForTests();
        results.add((await DeviceKeyService.instance.ensureKeyPair()).keyId);
      }

      expect(results.toSet(), {'fake-key-id-fingerprint'});
      expect(fake.ensureKeyPairCallCount, 3);
    });

    test('throws DeviceKeyUnavailableException (never a raw PlatformException) when native reports the key is unavailable', () async {
      final fake = FakeDeviceKeyChannel(
        throwOnEnsure: PlatformException(code: 'KEY_UNAVAILABLE', message: 'no keystore provider'),
      );
      addTearDown(fake.dispose);

      await expectLater(
        DeviceKeyService.instance.ensureKeyPair(),
        throwsA(isA<DeviceKeyUnavailableException>()),
      );
    });

    test('throws DeviceKeyUnavailableException when no native implementation exists for this platform at all', () async {
      // No FakeDeviceKeyChannel installed — the channel has no handler,
      // exactly matching a platform with no native plugin registered
      // (e.g. iOS before Phase 3, web, desktop).
      await expectLater(
        DeviceKeyService.instance.ensureKeyPair(),
        throwsA(isA<DeviceKeyUnavailableException>()),
      );
    });
  });

  group('getPublicKeyForRegistration', () {
    test('returns the same registration material shape as ensureKeyPair', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      final material = await DeviceKeyService.instance.getPublicKeyForRegistration();

      expect(material.keyId, 'fake-key-id-fingerprint');
      expect(material.publicKeyPem, contains('BEGIN PUBLIC KEY'));
    });
  });

  group('signCanonicalString', () {
    test('base64-encodes the given canonical string and returns the signature native provides', () async {
      final fake = FakeDeviceKeyChannel(signatureBase64: 'c2lnbmVkLWJ5LWFuZHJvaWQ=');
      addTearDown(fake.dispose);

      final signature = await DeviceKeyService.instance.signCanonicalString('hello canonical world');

      expect(signature, 'c2lnbmVkLWJ5LWFuZHJvaWQ=');
      final signCall = fake.calls.firstWhere((c) => c.method == 'sign');
      final sentBase64 = signCall.arguments['dataBase64'] as String;
      expect(utf8.decode(base64Decode(sentBase64)), 'hello canonical world');
    });

    test('ensures a key exists before attempting to sign', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      await DeviceKeyService.instance.signCanonicalString('data');

      expect(fake.calls.map((c) => c.method), containsAllInOrder(['ensureKeyPair', 'sign']));
    });

    test('signing repeatedly works correctly and does not require re-ensuring the key each time', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      await DeviceKeyService.instance.signCanonicalString('one');
      await DeviceKeyService.instance.signCanonicalString('two');
      await DeviceKeyService.instance.signCanonicalString('three');

      expect(fake.signCallCount, 3);
      expect(fake.ensureKeyPairCallCount, 1); // cached after the first
    });

    test('throws DeviceKeyUnavailableException when native signing fails, never returning a fabricated signature', () async {
      final fake = FakeDeviceKeyChannel(
        throwOnSign: PlatformException(code: 'NATIVE_ERROR', message: 'signature operation failed'),
      );
      addTearDown(fake.dispose);

      await expectLater(
        DeviceKeyService.instance.signCanonicalString('data'),
        throwsA(isA<DeviceKeyUnavailableException>()),
      );
    });

    test('never invokes any method that could expose private key material — only the documented, key-material-safe method names are ever called', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);

      await DeviceKeyService.instance.signCanonicalString('data');

      const allowedMethods = {'ensureKeyPair', 'sign'};
      for (final call in fake.calls) {
        expect(allowedMethods, contains(call.method));
      }
      // And the returned material itself carries nothing private-key-shaped.
      final material = await DeviceKeyService.instance.getPublicKeyForRegistration();
      expect(material.publicKeyPem, isNot(contains('PRIVATE KEY')));
    });
  });

  group('registerWithBackendIfNeeded', () {
    test('posts the public key material to POST /devices/keys and records success', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);
      http.BaseRequest? sentRequest;
      final httpFake = FakeHttpClient((request) async {
        sentRequest = request;
        return jsonStreamedResponse(201, {
          'deviceKey': {'id': 'dk-1', 'deviceId': 'd', 'keyId': 'k', 'algorithm': 'ECDSA_P256_SHA256', 'registeredAt': '2026-01-01T00:00:00.000Z', 'revokedAt': null},
          'reconciledEventCount': 0,
        });
      });
      ApiClient.instance = ApiClient(httpClient: httpFake);

      final result = await DeviceKeyService.instance.registerWithBackendIfNeeded();

      expect(result, true);
      expect(sentRequest, isNotNull);
      expect(sentRequest!.url.path, endsWith('/devices/keys'));
      final body = jsonDecode((sentRequest as http.Request).body) as Map<String, dynamic>;
      expect(body['keyId'], 'fake-key-id-fingerprint');
      expect(body['algorithm'], 'ECDSA_P256_SHA256');
      expect(body.containsKey('privateKey'), false);
    });

    test('skips the network call entirely once already registered for this exact keyId', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);
      var requestCount = 0;
      final httpFake = FakeHttpClient((request) async {
        requestCount++;
        return jsonStreamedResponse(201, {'deviceKey': {}, 'reconciledEventCount': 0});
      });
      ApiClient.instance = ApiClient(httpClient: httpFake);

      await DeviceKeyService.instance.registerWithBackendIfNeeded();
      await DeviceKeyService.instance.registerWithBackendIfNeeded();

      expect(requestCount, 1);
    });

    test('on a network/backend failure: returns false, does not mark as registered, and does NOT delete or regenerate the local key', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);
      final httpFake = FakeHttpClient((request) async => emptyStreamedResponse(500));
      ApiClient.instance = ApiClient(httpClient: httpFake);

      final result = await DeviceKeyService.instance.registerWithBackendIfNeeded();

      expect(result, false);
      expect(fake.calls.where((c) => c.method == 'deleteKeyPair'), isEmpty);
      // The same key is still there afterward — not regenerated.
      final material = await DeviceKeyService.instance.getPublicKeyForRegistration();
      expect(material.keyId, 'fake-key-id-fingerprint');
      expect(fake.ensureKeyPairCallCount, 1); // one generation only, never repeated due to the failure
    });

    test('retries automatically on the next call after a prior failure (no persistent "give up" state)', () async {
      final fake = FakeDeviceKeyChannel();
      addTearDown(fake.dispose);
      var attempt = 0;
      final httpFake = FakeHttpClient((request) async {
        attempt++;
        if (attempt == 1) return emptyStreamedResponse(500);
        return jsonStreamedResponse(201, {'deviceKey': {}, 'reconciledEventCount': 0});
      });
      ApiClient.instance = ApiClient(httpClient: httpFake);

      final firstResult = await DeviceKeyService.instance.registerWithBackendIfNeeded();
      final secondResult = await DeviceKeyService.instance.registerWithBackendIfNeeded();

      expect(firstResult, false);
      expect(secondResult, true);
      expect(attempt, 2);
    });

    test('returns false without attempting any HTTP call when the device key itself is unavailable', () async {
      final fake = FakeDeviceKeyChannel(
        throwOnEnsure: PlatformException(code: 'KEY_UNAVAILABLE', message: 'no keystore'),
      );
      addTearDown(fake.dispose);
      var requestCount = 0;
      final httpFake = FakeHttpClient((request) async {
        requestCount++;
        return emptyStreamedResponse(201);
      });
      ApiClient.instance = ApiClient(httpClient: httpFake);

      final result = await DeviceKeyService.instance.registerWithBackendIfNeeded();

      expect(result, false);
      expect(requestCount, 0);
    });
  });
}
