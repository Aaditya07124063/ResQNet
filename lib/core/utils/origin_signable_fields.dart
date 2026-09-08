import 'dart:convert';

/// The exact field set that gets cryptographically signed for origin
/// authentication of a (currently: mesh-relayed) SOS event. Mirrors
/// backend/src/utils/originSignature.ts's `SignableOriginFields`
/// interface field-for-field and MUST stay in exact sync with it — any
/// divergence here (a renamed field, a changed order, a different empty-
/// value convention) makes every signature this app produces fail
/// backend verification silently rather than loudly, since the backend
/// has no way to know what a client MEANT to sign, only what bytes it
/// actually received.
///
/// All fields are plain strings, including latitude/longitude/
/// locationAccuracyM and the two timestamps — never re-derived from a
/// parsed number/DateTime at signing time, because Dart's and JS's
/// floating-point-to-string / date-to-string formatting are not
/// guaranteed byte-identical. The caller is responsible for producing
/// these exact strings once (e.g. from GPS readings, formatted to a
/// fixed decimal precision) and reusing them verbatim everywhere this
/// event travels — signing, mesh transport, and eventual backend upload
/// all see the same strings.
class SignableOriginFields {
  final String protocolVersion;
  final String eventId;
  final String originDeviceId;
  final String eventType;
  final String eventSource;
  final String category;
  /// '' when there is no message — never left null.
  final String message;
  /// '' when there are no coordinates — never left null.
  final String latitude;
  final String longitude;
  final String locationAccuracyM;
  final String createdAt;
  final String expiresAt;
  final String maxHops;
  final String priority;

  const SignableOriginFields({
    required this.protocolVersion,
    required this.eventId,
    required this.originDeviceId,
    required this.eventType,
    required this.eventSource,
    required this.category,
    required this.message,
    required this.latitude,
    required this.longitude,
    required this.locationAccuracyM,
    required this.createdAt,
    required this.expiresAt,
    required this.maxHops,
    required this.priority,
  });
}

/// Matches originSignature.ts's SIGNING_DOMAIN exactly — a domain
/// separator so this signature can never be replayed as if it meant
/// something else.
const String _signingDomain = 'resqnet-sos-sig-v1';

/// Length-prefixed (netstring-style) framing — makes every field
/// boundary unambiguous regardless of what characters (including
/// newlines or digits) appear inside a free-text field like `message`,
/// matching originSignature.ts's `frame()` exactly (UTF-8 byte length,
/// not character count — matters for any non-ASCII message text).
String _frame(String value) {
  final byteLength = utf8.encode(value).length;
  return '$byteLength:$value';
}

/// Builds the exact canonical string that gets signed — pass the result
/// of this function directly to DeviceKeyService.signCanonicalString().
/// Field order here MUST exactly match originSignature.ts's FIELD_ORDER.
String buildSignableString(SignableOriginFields fields) {
  final ordered = <String>[
    _signingDomain,
    fields.protocolVersion,
    fields.eventId,
    fields.originDeviceId,
    fields.eventType,
    fields.eventSource,
    fields.category,
    fields.message,
    fields.latitude,
    fields.longitude,
    fields.locationAccuracyM,
    fields.createdAt,
    fields.expiresAt,
    fields.maxHops,
    fields.priority,
  ];
  return ordered.map(_frame).join();
}
