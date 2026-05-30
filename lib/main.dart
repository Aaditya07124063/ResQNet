import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/services/mesh_service.dart';
import 'core/services/sos_service.dart';
import 'core/services/location_service.dart';
import 'core/services/ai_service.dart';
import 'features/auth/auth_service.dart';
import 'firebase_options.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => MeshService()),
        ChangeNotifierProvider(create: (_) => SosService()),
        ChangeNotifierProvider(create: (_) => LocationService()),
        Provider(create: (_) => AiService()),
      ],
      child: const ResQNetApp(),
    ),
  );
}