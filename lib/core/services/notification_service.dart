import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emergency_message.dart';
import '../network/api_client.dart';
import '../notifications/notification_catalog.dart';
import '../../firebase_options.dart';

/// Background FCM handler. Every ResQNet push carries a `notification`
/// block, which the OS already displays while the app is in the background
/// — showing it again here would duplicate it, so this intentionally does
/// not display anything.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// A notification the user tapped, waiting to be opened by the navigator.
class NotificationTap {
  const NotificationTap(this.destination, this.params);

  final NotificationDestination destination;
  final Map<String, String> params;
}

/// Displays every ResQNet notification (backend push, offline mesh, and
/// on-device detection) through one pipeline:
///
/// - one channel per category (see [ResQNetChannel]) instead of making
///   everything maximum priority;
/// - one notification per event: a persisted, bounded record of shown
///   event keys stops the same emergency (arriving by mesh, push, and
///   socket, or re-delivered after reconnecting) from alerting twice;
/// - taps open the relevant screen via [pendingTap], including from a
///   cold start.
class NotificationService extends ChangeNotifier {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  FirebaseMessaging? _fcmInstance;
  FirebaseMessaging get _fcm => _fcmInstance ??= FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  Future<void>? _localReady;

  /// The most recent tapped notification not yet opened.
  final ValueNotifier<NotificationTap?> pendingTap = ValueNotifier<NotificationTap?>(null);

  final _dedup = NotificationDedupStore();

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _ensureLocalReady();

    try {
      // Firebase is used ONLY as the FCM push transport (the ResQNet
      // backend sends pushes through FCM, backend/src/services/fcm.ts).
      // Sign-in, data, and SOS all go through the ResQNet backend; nothing
      // else in the app initializes or uses Firebase.
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      // Foreground pushes are displayed by [_handleForegroundMessage] (with
      // deduplication), so the OS must not also present them.
      await _fcm.setForegroundNotificationPresentationOptions(alert: false, badge: true, sound: false);
      await _registerToken();
      _fcm.onTokenRefresh.listen(_saveToken);
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handlePushOpened);
      final initial = await _fcm.getInitialMessage();
      if (initial != null) _handlePushOpened(initial);
    } catch (e) {
      // Push is unavailable (no Play services, no network on first run);
      // local and mesh notifications still work.
      debugPrint('Push notifications unavailable: $e');
    }

    try {
      final launch = await _localNotifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _openPayload(launch!.notificationResponse?.payload);
      }
    } catch (e) {
      debugPrint('Notification launch details unavailable: $e');
    }
  }

  Future<void> _ensureLocalReady() => _localReady ??= _initLocal();

  Future<void> _initLocal() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Permission is requested through the app's permission flow, with an
    // explanation first — not implicitly on plugin initialization.
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (details) => _openPayload(details.payload),
    );

    // Creating a channel that already exists only updates its name and
    // description, so this is safe on every start.
    final android = _localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final channel in ResQNetChannel.all) {
      await android?.createNotificationChannel(AndroidNotificationChannel(
        channel.id,
        channel.name,
        description: channel.description,
        importance: _importance(channel.level),
        playSound: true,
        enableVibration: channel.level != NotificationLevel.normal,
      ));
    }
  }

  Future<void> _registerToken() async {
    try {
      final token = await _fcm.getToken();
      if (token != null) await _saveToken(token);
    } catch (e) {
      debugPrint('FCM token fetch failed: $e');
    }
  }

  /// Registers the FCM token with the ResQNet backend (`POST /api/v1/devices`).
  /// Best-effort: without a backend session this simply fails and is
  /// retried on the next start; local notifications do not depend on it.
  Future<void> _saveToken(String token) async {
    try {
      await ApiClient.instance.post(
        '/devices',
        auth: true,
        body: {
          'platform': Platform.isIOS ? 'ios' : 'android',
          'pushProvider': 'fcm',
          'pushToken': token,
        },
      );
    } catch (e) {
      debugPrint('Device token registration error: $e');
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final spec = specForPush(
      message.data,
      title: message.notification?.title,
      body: message.notification?.body,
    );
    if (spec != null) unawaited(show(spec));
  }

  void _handlePushOpened(RemoteMessage message) {
    final spec = specForPush(
      message.data,
      title: message.notification?.title,
      body: message.notification?.body,
    );
    if (spec != null) pendingTap.value = NotificationTap(spec.destination, spec.params);
  }

  void _openPayload(String? payload) {
    final parsed = parseNotificationPayload(payload);
    pendingTap.value = NotificationTap(parsed.destination, parsed.params);
  }

  /// Raises a local notification for an emergency received over the mesh
  /// (the offline path — no backend involved).
  Future<void> notifyMeshMessage(EmergencyMessage message, {bool cancellationVerified = false}) async {
    final spec = specForMeshMessage(message, cancellationVerified: cancellationVerified);
    if (spec != null) await show(spec);
  }

  /// Shows [spec] unless the same event was already shown.
  Future<bool> show(NotificationSpec spec) async {
    if (!await _dedup.markIfNew(spec.dedupKey)) return false;
    try {
      await _ensureLocalReady();
      final level = spec.channel.level;
      await _localNotifications.show(
        // Android identifies a notification by (tag, id); using the tag as
        // the key lets a backend push with the same tag replace it.
        Platform.isAndroid ? 0 : spec.notificationId,
        spec.title,
        spec.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            spec.channel.id,
            spec.channel.name,
            channelDescription: spec.channel.description,
            importance: _importance(level),
            priority: level == NotificationLevel.normal ? Priority.defaultPriority : Priority.high,
            category: level == NotificationLevel.critical ? AndroidNotificationCategory.alarm : null,
            tag: spec.tag,
            icon: '@mipmap/ic_launcher',
            color: const Color(0xFFD32F2F),
            styleInformation: BigTextStyleInformation(spec.body),
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: level != NotificationLevel.normal,
            // Time-sensitive only for real emergencies; requires the
            // Time Sensitive Notifications capability to take effect.
            interruptionLevel:
                level == NotificationLevel.critical ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
            threadIdentifier: spec.channel.id,
          ),
        ),
        payload: spec.payload,
      );
      return true;
    } catch (e) {
      debugPrint('Notification display failed: $e');
      return false;
    }
  }

  /// Removes the notification occupying [spec]'s slot (e.g. a detection
  /// countdown the user cancelled).
  Future<void> dismiss(NotificationSpec spec) async {
    try {
      await _localNotifications.cancel(Platform.isAndroid ? 0 : spec.notificationId, tag: spec.tag);
    } catch (e) {
      debugPrint('Notification dismiss failed: $e');
    }
  }

  static Importance _importance(NotificationLevel level) {
    switch (level) {
      case NotificationLevel.critical:
        return Importance.max;
      case NotificationLevel.high:
        return Importance.high;
      case NotificationLevel.normal:
        return Importance.defaultImportance;
    }
  }
}

/// Persisted, bounded record of which events have already produced a
/// notification — survives restarts, so an event re-delivered after
/// reconnecting (queued push, mesh re-send) does not alert again.
class NotificationDedupStore {
  NotificationDedupStore({this.maxEntries = 300, this.retention = const Duration(hours: 48)});

  final int maxEntries;
  final Duration retention;
  static const _key = 'resqnet_notification_keys_v1';
  final Set<String> _session = {};
  Future<void> _chain = Future<void>.value();

  /// Records [key] and returns true if it had not been seen before.
  Future<bool> markIfNew(String key) {
    final result = _chain.then((_) => _markIfNew(key));
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _markIfNew(String key) async {
    if (_session.contains(key)) return false;
    _session.add(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final map = raw == null ? <String, String>{} : Map<String, String>.from(jsonDecode(raw) as Map<String, dynamic>);
      if (map.containsKey(key)) return false;
      final now = DateTime.now();
      map[key] = now.toIso8601String();
      map.removeWhere((_, seen) => now.difference(DateTime.tryParse(seen) ?? now) > retention);
      if (map.length > maxEntries) {
        final sorted = map.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
        for (final entry in sorted.take(map.length - maxEntries)) {
          map.remove(entry.key);
        }
      }
      await prefs.setString(_key, jsonEncode(map));
    } catch (e) {
      // Storage failure must not suppress an emergency notification.
      debugPrint('Notification dedup store unavailable: $e');
    }
    return true;
  }
}
