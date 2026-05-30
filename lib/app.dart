import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'core/constants/app_colors.dart';
import 'core/constants/app_routes.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/sos/sos_screen.dart';
import 'features/mesh/mesh_screen.dart';
import 'features/map/map_screen.dart';
import 'features/dashboard/dashboard_screen.dart';

class ResQNetApp extends StatelessWidget {
  const ResQNetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ResQNet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: AppColors.emergencyRed,
          secondary: AppColors.warningAmber,
          surface: AppColors.surfaceDark,
        ),
        scaffoldBackgroundColor: AppColors.backgroundDark,
        useMaterial3: true,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: AppColors.backgroundDark,
              body: Center(
                child: CircularProgressIndicator(
                    color: AppColors.emergencyRed),
              ),
            );
          }
          if (snapshot.hasData && snapshot.data != null) {
            return const HomeScreen();
          }
          return const LoginScreen();
        },
      ),
      routes: {
        AppRoutes.sos: (_) => const SosScreen(),
        AppRoutes.mesh: (_) => const MeshScreen(),
        AppRoutes.map: (_) => const MapScreen(),
        AppRoutes.dashboard: (_) => const DashboardScreen(),
      },
    );
  }
}