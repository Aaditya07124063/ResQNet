// Static checks for the Firebase → ResQNet backend migration: sign-in and
// data must not depend on Firebase Auth/Firestore, while FCM (the push
// transport the backend uses) is intentionally kept.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

Iterable<File> dartFiles(String dir) =>
    Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  test('Firebase Auth and Firestore are not dependencies', () {
    expect(pubspec, isNot(contains('firebase_auth')));
    expect(pubspec, isNot(contains('cloud_firestore')));
  });

  test('no app code uses Firebase Auth or Firestore', () {
    for (final file in dartFiles('lib')) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('package:firebase_auth/')), reason: file.path);
      expect(source, isNot(contains('package:cloud_firestore/')), reason: file.path);
      expect(source, isNot(contains('FirebaseAuth.instance')), reason: file.path);
      expect(source, isNot(contains('FirebaseFirestore.instance')), reason: file.path);
    }
  });

  test('the auth gate does not use Firebase', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, isNot(contains('authStateChanges')));
    expect(app, isNot(contains('firebase')));
    expect(app, contains('backendSession'));
  });

  test('Firebase is initialized only by the notification service, for FCM', () {
    final initializers = dartFiles('lib')
        .where((f) => f
            .readAsLinesSync()
            .any((line) => !line.trimLeft().startsWith('//') && line.contains('Firebase.initializeApp')))
        .map((f) => f.path.replaceAll(r'\', '/'))
        .toList();
    expect(initializers, ['lib/core/services/notification_service.dart']);
    expect(File('lib/main.dart').readAsStringSync(), isNot(contains('firebase')));
  });

  test('FCM push remains: dependency, token registration with the backend, and message handlers', () {
    expect(pubspec, contains('firebase_messaging'));
    final notifications = File('lib/core/services/notification_service.dart').readAsStringSync();
    expect(notifications, contains("'/devices'"));
    expect(notifications, contains('FirebaseMessaging.onMessage'));
    expect(notifications, contains('FirebaseMessaging.onMessageOpenedApp'));
    expect(notifications, contains('getInitialMessage'));
  });

  test('Android no longer applies the Google Services Gradle plugin, and keeps com.resqnet.app', () {
    final app = File('android/app/build.gradle.kts').readAsStringSync();
    expect(app, isNot(contains('google-services')));
    expect(app, isNot(contains('firebase-bom')));
    expect(app, contains('applicationId = "com.resqnet.app"'));
    expect(File('android/settings.gradle.kts').readAsStringSync(), isNot(contains('google-services')));
    expect(File('android/build.gradle.kts').readAsStringSync(), isNot(contains('google-services')));
  });
}
