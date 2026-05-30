import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/services/ai_service.dart';
import 'core/services/location_service.dart';
import 'core/services/mesh_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/sos_service.dart';
import 'features/auth/auth_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize push notifications
  try {
    await NotificationService().initialize();
  } catch (e) {
    debugPrint('NotificationService init failed: $e');
  }

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
      ],
      child: const ResQNetApp(),
    ),
  );
}