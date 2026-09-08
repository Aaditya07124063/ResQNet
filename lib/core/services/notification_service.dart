import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../network/api_client.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(const InitializationSettings(android: androidSettings));

  const channel = AndroidNotificationChannel(
    'resqnet_emergency',
    'Emergency Alerts',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  final notification = message.notification;
  if (notification != null) {
    plugin.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFFD32F2F),
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }
}

class NotificationService extends ChangeNotifier {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'resqnet_emergency',
    'Emergency Alerts',
    description: 'Critical emergency notifications from ResQNet',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Background handler must be registered first
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Set foreground notification presentation
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Local notifications setup
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (details) {
        debugPrint('Notification tapped: ${details.payload}');
      },
    );

    // Create Android channel
    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // Save FCM token
    await _saveTokenToFirestore();
    _fcm.onTokenRefresh.listen(_saveToken);

    // Foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
  }

  Future<void> _saveTokenToFirestore() async {
    try {
      final token = await _fcm.getToken();
      if (token != null) await _saveToken(token);
    } catch (e) {
      debugPrint('FCM token fetch failed: $e');
    }
  }

  /// Phase 20: registers the FCM token with the ResQNet backend
  /// (`POST /api/v1/devices`, Phase 17) instead of Firestore's
  /// `user_tokens/{uid}` — the backend now owns push-sending itself
  /// (`pushNotificationService.ts`), so this is the only registration
  /// that matters going forward. Best-effort and silent on failure,
  /// matching the Firestore write's own error handling: a user who
  /// hasn't completed backend Google/phone sign-in yet (no stored
  /// backend access token) simply can't register a device server-side
  /// until they do — this never blocks local notification delivery,
  /// which works from the FCM token alone.
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
    final notification = message.notification;
    if (notification == null) return;

    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFFD32F2F),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('Notification tapped: ${message.data}');
  }

  // Phase 20: `broadcastSosNotification()` (a Firestore `sos_broadcasts`
  // write that used to trigger the `sendSosNotification` Cloud Function)
  // has been removed — the backend's `POST /api/v1/sos` now sends this
  // same broadcast itself (`pushNotificationService.notifyAllOtherActiveUsers`,
  // Phase 17), as part of creating the SOS event. See sos_service.dart's
  // `triggerSos()`, which now calls the backend directly instead of this
  // method.
}