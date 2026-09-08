import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/services/ai_service.dart';
import 'core/services/app_shortcut_service.dart';
import 'core/services/background_detection_service.dart';
import 'core/services/communication_service.dart';
import 'core/services/crash_detection_service.dart';
import 'core/services/detection_logging_service.dart';
import 'core/services/driving_context_service.dart';
import 'core/services/earthquake_correlation_service.dart';
import 'core/services/earthquake_feed_service.dart';
import 'core/services/emergency_communication_service.dart';
import 'core/services/emergency_contacts_service.dart';
import 'core/services/government_alert_feed_service.dart';
import 'core/services/hazard_service.dart';
import 'core/services/location_service.dart';
import 'core/services/mesh_service.dart';
import 'core/services/nearby_alert_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/profile_service.dart';
import 'core/services/safe_zone_service.dart';
import 'core/services/seismic_service.dart';
import 'core/services/sensor_recorder_service.dart';
import 'core/services/sos_service.dart';
import 'core/services/theme_service.dart';
import 'core/services/trusted_contacts_service.dart';
import 'core/services/voice_note_service.dart';
import 'features/auth/auth_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize offline map tile caching (FMTC v9 — ObjectBox backend)
  await FMTCObjectBoxBackend().initialise();
  await const FMTCStore('mapStore').manage.create();

  // Home-screen SOS: registers the Android App Shortcut / iOS Home Screen
  // Quick Action. This only lets the OS re-launch/foreground the app with
  // a signal — see AppShortcutService's own doc comment for why the
  // actual authenticated SOS call deliberately still happens entirely
  // inside HomeScreen, reusing the existing SosScreen/SosService/
  // SosDispatchService flow unchanged.
  final appShortcutService = AppShortcutService();
  appShortcutService.init().catchError(
    (e) => debugPrint('AppShortcutService init error: $e'),
  );

  final aiService = AiService();
  final locationService = LocationService();
  final meshService = MeshService();
  final hazardService = HazardService();
  final safeZoneService = SafeZoneService();
  final detectionLoggingService = DetectionLoggingService();
  detectionLoggingService.loadPreference();
  BackgroundDetectionService.init();
  final earthquakeFeedService = EarthquakeFeedService();
  // Shared with SensorRecorderService below so a recording session never
  // opens a second GPS listener alongside the crash detector's own.
  final drivingContextService = DrivingContextService();
  final crashDetectionService = CrashDetectionService(
    drivingContext: drivingContextService,
    logger: detectionLoggingService,
  );
  final seismicService = SeismicService(
    correlation: EarthquakeCorrelationService(),
    logger: detectionLoggingService,
  );
  final sensorRecorderService = SensorRecorderService(
    locationService: locationService,
    crashDetection: crashDetectionService,
    seismicDetection: seismicService,
    drivingContext: drivingContextService,
  );

  // USGS/EMSC are real public feeds — a cross-check signal only, never a
  // gate on local detection (see EarthquakeFeedService's docs).
  earthquakeFeedService.start();

  // Future government/authority disaster-alert integration point: set
  // GovernmentAlertFeedService.feedUrl and this starts polling it, turning
  // each alert into a Hazard (danger) or a SafeZone/SafeRoute ("this way is
  // safe") that also relays over the offline mesh.
  // No-ops until a feed URL is configured — see the file for details.
  GovernmentAlertFeedService(hazardService, safeZoneService, meshService)
      .start();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => aiService),
        ChangeNotifierProvider(create: (_) => locationService),
        ChangeNotifierProvider(
          create: (_) => SosService(aiService, locationService),
        ),
        ChangeNotifierProvider.value(value: meshService),
        ChangeNotifierProvider.value(value: hazardService),
        ChangeNotifierProvider.value(value: safeZoneService),
        ChangeNotifierProvider(create: (_) => NotificationService()),
        ChangeNotifierProvider(create: (_) => ThemeService()),
        ChangeNotifierProvider(create: (_) => ProfileService()),
        ChangeNotifierProvider(create: (_) => EmergencyContactsService()),
        ChangeNotifierProvider.value(value: crashDetectionService),
        ChangeNotifierProvider.value(value: seismicService),
        ChangeNotifierProvider.value(value: detectionLoggingService),
        ChangeNotifierProvider.value(value: sensorRecorderService),
        ChangeNotifierProvider.value(value: earthquakeFeedService),
        ChangeNotifierProvider(create: (_) => VoiceNoteService()),
        ChangeNotifierProvider(create: (_) => TrustedContactsService()),
        ChangeNotifierProvider(create: (_) => CommunicationService()),
        ChangeNotifierProvider(create: (_) => NearbyAlertService()),
        ChangeNotifierProvider(create: (_) => EmergencyCommunicationService()),
        Provider<AppShortcutService>.value(value: appShortcutService),
      ],
      child: const ResQNetApp(),
    ),
  );
}