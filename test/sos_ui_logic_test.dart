import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/models/sos_alert.dart';
import 'package:resqnet/core/network/api_exception.dart';
import 'package:resqnet/core/services/location_service.dart';
import 'package:resqnet/core/utils/medical_summary.dart';
import 'package:resqnet/core/utils/permission_handler.dart';
import 'package:resqnet/features/auth/phone_otp_mode.dart';
import 'package:resqnet/features/sos/sos_status.dart';

SosAlert alert({double? lat, double? lng}) => SosAlert(
      id: 'e1',
      userId: 'u',
      userName: 'A',
      category: SosCategory.general,
      message: 'help',
      latitude: lat,
      longitude: lng,
      locationAccuracyM: lat != null ? 12 : null,
      timestamp: DateTime.now(),
    );

EmergencyOutboxEntry entry(OutboxEntryState state, {int attempts = 0, String? lastError}) => EmergencyOutboxEntry(
      eventId: 'e1',
      eventSource: 'manual',
      category: 'general',
      createdAt: DateTime.now(),
      state: state,
      attempts: attempts,
      lastError: lastError,
    );

List<SosStatusLine> describe({
  SosAlert? a,
  EmergencyOutboxEntry? e,
  int reached = 0,
  int connected = 0,
  bool running = true,
  bool? network = true,
  LocationStatus location = LocationStatus.available,
}) =>
    describeActiveSos(
      alert: a ?? alert(lat: 27.7, lng: 85.3),
      entry: e ?? entry(OutboxEntryState.queued),
      meshPeersReached: reached,
      meshConnectedPeers: connected,
      meshRunning: running,
      hasNetwork: network,
      locationStatus: location,
    );

void main() {
  group('active SOS status never overstates delivery', () {
    test('no peers yet: mesh is "searching", not "sent"', () {
      final mesh = describe()[1];
      expect(mesh.tone, SosStatusTone.pending);
      expect(mesh.value, isNot(contains('Handed')));
    });

    test('peers reached are reported as a handoff count', () {
      final mesh = describe(reached: 2, connected: 2)[1];
      expect(mesh.value, contains('Handed to 2 nearby ResQNet devices'));
      expect(mesh.value.toLowerCase(), isNot(contains('delivered')));
    });

    test('mesh not running is a problem the user can act on', () {
      expect(describe(running: false)[1].tone, SosStatusTone.problem);
    });

    test('no internet: the server line says it will send later', () {
      final server = describe(network: false)[2];
      expect(server.tone, SosStatusTone.pending);
      expect(server.value, contains('No internet'));
    });

    test('server acceptance is the only "received" state', () {
      expect(describe(e: entry(OutboxEntryState.serverAccepted))[2].value, startsWith('Received'));
      for (final state in [OutboxEntryState.queued, OutboxEntryState.serverPending, OutboxEntryState.failed]) {
        expect(describe(e: entry(state))[2].value, isNot(startsWith('Received')));
      }
    });

    test('a session problem is explained without blocking offline paths', () {
      final server = describe(e: entry(OutboxEntryState.failed, lastError: 'UNAUTHORIZED: expired'))[2];
      expect(server.value, contains('Not signed in'));
      expect(server.value, contains('nearby devices and SMS still work'));
    });

    test('missing location explains why and offers settings when permission is the cause', () {
      final line = describe(a: alert(), location: LocationStatus.permissionDeniedForever)[0];
      expect(line.tone, SosStatusTone.problem);
      expect(line.action, SosStatusAction.openLocationSettings);
      expect(describe(a: alert(), location: LocationStatus.unavailable)[0].action, isNull);
    });

    test('included location shows coordinates and accuracy', () {
      expect(describe()[0].value, contains('±12 m'));
    });
  });

  test('resolution descriptions never claim an unsynced server update', () {
    final pending = entry(OutboxEntryState.serverAccepted)
        .copyWith(resolution: SosResolution.resolved, resolutionSync: ResolutionSyncState.pending);
    expect(describeResolution(pending), contains('when online'));
    final synced = pending.copyWith(resolutionSync: ResolutionSyncState.synced);
    expect(describeResolution(synced), contains('server updated'));
  });

  test('elapsed time formatting', () {
    expect(formatElapsed(const Duration(seconds: 42)), '42s');
    expect(formatElapsed(const Duration(minutes: 3, seconds: 5)), '3m 5s');
    expect(formatElapsed(const Duration(hours: 2, minutes: 1)), '2h 1m');
  });

  group('permissions', () {
    test('granted only when every permission in the group is granted', () {
      expect(combinePermissionStatuses([PermissionStatus.granted, PermissionStatus.granted]),
          GroupPermissionState.granted);
      expect(
          combinePermissionStatuses([PermissionStatus.granted, PermissionStatus.denied]), GroupPermissionState.denied);
    });

    test('permanently denied (or restricted) needs the settings app', () {
      expect(combinePermissionStatuses([PermissionStatus.granted, PermissionStatus.permanentlyDenied]),
          GroupPermissionState.permanentlyDenied);
      expect(combinePermissionStatuses([PermissionStatus.restricted]), GroupPermissionState.permanentlyDenied);
    });

    test('no microphone/camera/photos permission is requested up front', () {
      for (final android in [true, false]) {
        final all = resqnetPermissionGroups(isAndroid: android).expand((g) => g.permissions);
        expect(all, isNot(contains(Permission.microphone)));
        expect(all, isNot(contains(Permission.camera)));
        expect(all, isNot(contains(Permission.photos)));
        expect(all, isNot(contains(Permission.locationAlways)));
      }
    });
  });

  group('phone OTP error messages', () {
    test('network failures point to offline SOS instead of a generic error', () {
      expect(describeOtpSendError(ApiException.network('x')), contains('SOS still works'));
    });

    test('cooldown, bad number, and server failures are distinguished', () {
      expect(describeOtpSendError(const ApiException(statusCode: 429, code: 'X', message: 'm')), contains('wait'));
      expect(
          describeOtpSendError(const ApiException(statusCode: 400, code: 'X', message: 'm')), contains('phone number'));
      expect(describeOtpSendError(const ApiException(statusCode: 500, code: 'X', message: 'secret detail')),
          isNot(contains('secret detail')));
    });

    test('verification failures are one generic message, never revealing why', () {
      expect(describeOtpVerifyError(const ApiException(statusCode: 401, code: 'X', message: 'expired')),
          'That code is invalid or has expired. Check it, or request a new one.');
    });
  });

  group('medical summary', () {
    test('empty fields are omitted rather than broadcast as blank labels', () {
      expect(medicalSummary('', ''), '');
      expect(medicalSummary('O+', ''), '\nBlood: O+');
      expect(medicalSummary(' O+ ', 'penicillin'), '\nBlood: O+ | Allergies: penicillin');
    });
  });
}
