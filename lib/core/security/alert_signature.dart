import 'dart:convert';
import '../utils/origin_signature_verifier.dart';

/// Verification of emergency alerts signed by the ResQNet server, so an
/// alert relayed over the offline mesh keeps its source label (e.g.
/// OFFICIAL) only when it is exactly what the server issued. Mirrors
/// backend/src/utils/alertSignature.ts byte for byte.

const alertSignatureVersion = 'resqnet-alert-v1';

/// The server's alert-signing public key, provided at build time as base64
/// of the SPKI PEM: `--dart-define=RESQNET_ALERT_PUBLIC_KEY=...`. Empty
/// means no key is pinned, so no relayed alert can be verified.
const String _pinnedKeyBase64 = String.fromEnvironment('RESQNET_ALERT_PUBLIC_KEY');

String? pinnedAlertPublicKeyPem() {
  if (_pinnedKeyBase64.isEmpty) return null;
  try {
    return utf8.decode(base64Decode(_pinnedKeyBase64));
  } catch (_) {
    return null;
  }
}

String _field(String value) => '${utf8.encode(value).length}:$value';

String _fixed(Object? n, int digits) => n is num ? n.toStringAsFixed(digits) : '';

String? _str(Object? v) => v is String ? v : null;

/// Canonical signed form of a server alert (as JSON from `GET /alerts`).
/// Returns null if the alert is missing a required field.
String? canonicalAlertString(Map<String, dynamic> alert) {
  final area = alert['area'];
  if (area is! Map) return null;
  final required = ['id', 'sourceType', 'sourceName', 'category', 'severity', 'status', 'title', 'body', 'issuedAt', 'updatedAt'];
  for (final key in required) {
    if (alert[key] is! String) return null;
  }
  final values = <String>[
    alert['id'],
    alert['sourceType'],
    alert['sourceName'],
    alert['category'],
    alert['severity'],
    alert['status'],
    alert['title'],
    alert['body'],
    _str(alert['instructions']) ?? '',
    _fixed(area['latitude'], 6),
    _fixed(area['longitude'], 6),
    _fixed(area['radiusKm'], 3),
    _str(area['province']) ?? '',
    _str(area['district']) ?? '',
    _str(area['municipality']) ?? '',
    alert['issuedAt'],
    _str(alert['expiresAt']) ?? '',
    alert['updatedAt'],
  ];
  return alertSignatureVersion + values.map(_field).join();
}

/// True only if [alert] carries a signature that verifies against
/// [publicKeyPem] (defaults to the pinned key).
bool verifyServerAlert(Map<String, dynamic> alert, {String? publicKeyPem}) {
  final key = publicKeyPem ?? pinnedAlertPublicKeyPem();
  final signature = alert['signature'];
  if (key == null || signature is! String) return false;
  final canonical = canonicalAlertString(alert);
  if (canonical == null) return false;
  return verifyP256DerSignature(publicKeyPem: key, message: utf8.encode(canonical), signatureBase64: signature);
}
