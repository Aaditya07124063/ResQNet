import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps crash + earthquake detection alive when ResQNet isn't in the
/// foreground.
///
/// Deliberately simple: this does NOT spawn a separate background
/// isolate/TaskHandler running its own copy of the detection logic —
/// CrashDetectionService and SeismicService keep running exactly as
/// before, in the app's normal (main) isolate, using the same
/// MotionSensorService/DrivingContextService instances already
/// registered with Provider. What this adds is an Android foreground
/// service (a persistent, low-priority notification) whose only job is
/// to stop the OS from killing that process while the app is
/// backgrounded — the actual sensor listening is unchanged.
///
/// Platform reality worth being direct about: Android's foreground
/// service genuinely keeps the process alive indefinitely (subject to
/// OEM-specific battery-optimization behavior — see BeSafeBox's
/// documented experience with exactly this). iOS has no equivalent —
/// Apple's background execution is time-limited even with a declared
/// background mode, so "background operation" on iOS is meaningfully
/// weaker than on Android regardless of what's built here. That's an OS
/// policy limit, not something a plugin works around.
class BackgroundDetectionService {
  BackgroundDetectionService._();

  static const String _channelId = 'resqnet_safety_monitoring';
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: 'Safety Monitoring',
        channelDescription:
            'Keeps crash and earthquake detection running while ResQNet is in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      // iOS shows no separate notification for this — its background
      // execution window is tied to the OS-declared background modes,
      // not a persistent notification the way Android's is.
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No repeat callback — detection is event-driven off the sensor
        // streams already running in the main isolate, not a polling
        // loop this service needs to drive.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<bool> start() async {
    init();
    if (await FlutterForegroundTask.isRunningService) return true;

    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.location],
      notificationTitle: 'ResQNet Safety Monitoring',
      notificationText: 'Watching for crashes and earthquakes',
    );

    if (result is ServiceRequestFailure) {
      debugPrint('BackgroundDetectionService start failed: ${result.error}');
      return false;
    }
    return true;
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
