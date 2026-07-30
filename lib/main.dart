import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/services/ai_service.dart';
import 'core/services/crash_detection_service.dart';
import 'core/services/emergency_contacts_service.dart';
import 'core/services/location_service.dart';
import 'core/services/mesh_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/profile_service.dart';
import 'core/services/seismic_service.dart';
import 'core/services/sos_service.dart';
import 'core/services/theme_service.dart';
import 'features/auth/auth_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize offline map tile caching (FMTC v9 — ObjectBox backend)
  await FMTCObjectBoxBackend().initialise();
  await const FMTCStore('mapStore').manage.create();

  final aiService = AiService();
  final locationService = LocationService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => aiService),
        ChangeNotifierProvider(create: (_) => locationService),
        ChangeNotifierProvider(
          create: (_) => SosService(aiService, locationService),
        ),
        ChangeNotifierProvider(create: (_) => MeshService()),
        ChangeNotifierProvider(create: (_) => NotificationService()),
        ChangeNotifierProvider(create: (_) => ThemeService()),
        ChangeNotifierProvider(create: (_) => ProfileService()),
        ChangeNotifierProvider(create: (_) => EmergencyContactsService()),
        ChangeNotifierProvider(create: (_) => CrashDetectionService()),
        ChangeNotifierProvider(create: (_) => SeismicService()),
      ],
      child: const ResQNetApp(),
    ),
  );
}