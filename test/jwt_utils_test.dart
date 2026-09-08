import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/network/jwt_utils.dart';

String _fakeJwt(Map<String, dynamic> payload) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final body = encode(payload);
  return '$header.$body.fake-signature';
}

void main() {
  group('isJwtExpired', () {
    test('a token with an exp far in the future is not expired', () {
      final token = _fakeJwt({
        'sub': 'user-1',
        'exp': DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000,
      });
      expect(isJwtExpired(token), isFalse);
    });

    test('a token with an exp in the past is expired', () {
      final token = _fakeJwt({
        'sub': 'user-1',
        'exp': DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
      });
      expect(isJwtExpired(token), isTrue);
    });

    test('a token expiring just within the leeway window counts as expired', () {
      final token = _fakeJwt({
        'sub': 'user-1',
        'exp': DateTime.now().add(const Duration(seconds: 10)).millisecondsSinceEpoch ~/ 1000,
      });
      expect(isJwtExpired(token, leeway: const Duration(seconds: 30)), isTrue);
    });

    test('a malformed token (wrong number of segments) is treated as expired', () {
      expect(isJwtExpired('not-a-jwt'), isTrue);
    });

    test('a token with unparseable base64/JSON in the payload is treated as expired', () {
      expect(isJwtExpired('header.@@not-valid-base64@@.sig'), isTrue);
    });

    test('a token missing the exp claim is treated as expired', () {
      final token = _fakeJwt({'sub': 'user-1'});
      expect(isJwtExpired(token), isTrue);
    });

    test('a token with a non-numeric exp claim is treated as expired', () {
      final token = _fakeJwt({'sub': 'user-1', 'exp': 'not-a-number'});
      expect(isJwtExpired(token), isTrue);
    });
  });
}
