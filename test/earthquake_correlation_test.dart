import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:resqnet/core/models/earthquake_evidence.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/earthquake_correlation_service.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

Position kathmandu() => Position(
      latitude: 27.7172,
      longitude: 85.324,
      timestamp: DateTime.now(),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

EarthquakeEvidence evidence({double staLta = 4.5}) => EarthquakeEvidence(
      ratioScore: 0.9,
      durationScore: 0.8,
      oscillationScore: 0.7,
      totalConfidence: 0.82,
      staLtaRatio: staLta,
      sustainedDuration: const Duration(milliseconds: 1500),
      oscillationCount: 9,
    );

void main() {
  late FakeSecureStorage secureStorage;
  late List<http.Request> requests;

  setUp(() async {
    secureStorage = FakeSecureStorage();
    requests = [];
    await TokenStorage.instance.save(accessToken: 'access', refreshToken: 'refresh');
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  test('reports the candidate to the ResQNet backend with the session token and reads corroboration back', () async {
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((r) async {
      requests.add(r as http.Request);
      return jsonStreamedResponse(201, {
        'result': {'reportId': 'x', 'corroboratingDeviceCount': 3, 'corroborated': true, 'alertSent': true},
      });
    }));

    final result = await EarthquakeCorrelationService(lastKnownPosition: () async => kathmandu()).reportCandidate(evidence());

    final request = requests.single;
    expect(request.url.toString(), endsWith('/api/v1/seismic/reports'));
    expect(request.headers['Authorization'], 'Bearer access');
    expect(jsonDecode(request.body), {
      'latitude': 27.7172,
      'longitude': 85.324,
      'detectorScore': 0.82,
      'staLtaRatio': 4.5,
      'sustainedDurationMs': 1500,
      'oscillationCount': 9,
    });
    expect(result!.deviceCount, 3);
    expect(result.corroborated, isTrue);
  });

  test('no location: nothing is sent', () async {
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => fail('no request expected')));
    expect(await EarthquakeCorrelationService(lastKnownPosition: () async => null).reportCandidate(evidence()), isNull);
  });

  test('offline: the report is dropped without throwing (never replayed later as a stale quake)', () async {
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => throw const SocketException('offline')));
    expect(await EarthquakeCorrelationService(lastKnownPosition: () async => kathmandu()).reportCandidate(evidence()), isNull);
  });

  test('a non-finite detector ratio is omitted rather than rejected by the server', () async {
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((r) async {
      requests.add(r as http.Request);
      return jsonStreamedResponse(201, {'result': {'corroboratingDeviceCount': 1, 'corroborated': false}});
    }));
    await EarthquakeCorrelationService(lastKnownPosition: () async => kathmandu()).reportCandidate(evidence(staLta: double.infinity));
    expect((jsonDecode(requests.single.body) as Map).containsKey('staLtaRatio'), isFalse);
  });
}
