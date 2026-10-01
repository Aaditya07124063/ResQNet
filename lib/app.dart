import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/constants/app_routes.dart';
import 'core/network/backend_session_controller.dart';
import 'core/services/theme_service.dart';
import 'features/auth/auth_service.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/employee/employee_portal_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/sos/sos_screen.dart';
import 'features/mesh/mesh_screen.dart';
import 'features/map/map_screen.dart';
import 'features/dashboard/dashboard_screen.dart';

class ResQNetApp extends StatelessWidget {
  const ResQNetApp({super.key});

  ThemeData _darkTheme(Color primary) {
    return ThemeData.dark().copyWith(
      colorScheme: ColorScheme.dark(primary: primary, secondary: primary),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      cardColor: const Color(0xFF2A2A2A),
      dialogBackgroundColor: const Color(0xFF1E1E1E),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
            backgroundColor: primary, foregroundColor: Colors.white),
      ),
      floatingActionButtonTheme:
          FloatingActionButtonThemeData(backgroundColor: primary),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? primary : Colors.grey),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? primary.withOpacity(0.4)
                : Colors.grey.withOpacity(0.3)),
      ),
    );
  }

  ThemeData _lightTheme(Color primary) {
    return ThemeData.light().copyWith(
      colorScheme: ColorScheme.light(primary: primary, secondary: primary),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.black87),
        elevation: 1,
        titleTextStyle: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 18),
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      cardColor: Colors.white,
      dialogBackgroundColor: Colors.white,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
            backgroundColor: primary, foregroundColor: Colors.white),
      ),
      floatingActionButtonTheme:
          FloatingActionButtonThemeData(backgroundColor: primary),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? primary : Colors.grey),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? primary.withOpacity(0.4)
                : Colors.grey.withOpacity(0.3)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Colors.grey[800],
        contentTextStyle: const TextStyle(color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeService = context.watch<ThemeService>();
    const primary = ThemeService.primaryColor;

    return MaterialApp(
      title: 'ResQNet',
      debugShowCheckedModeBanner: false,
      theme: themeService.isDarkMode
          ? _darkTheme(primary)
          : _lightTheme(primary),
      home: FutureBuilder<bool>(
        future: SharedPreferences.getInstance()
            .then((p) => p.getBool('onboarding_done') ?? false),
        builder: (context, snap) {
          if (!snap.hasData) {
            return Scaffold(
              backgroundColor: const Color(0xFF121212),
              body: Center(
                  child: CircularProgressIndicator(color: primary)),
            );
          }
          if (snap.data == false) {
            return OnboardingScreen(
              onDone: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const _AuthGate()),
              ),
            );
          }
          return const _AuthGate();
        },
      ),
      routes: {
        AppRoutes.sos: (_) => const SosScreen(),
        AppRoutes.mesh: (_) => const MeshScreen(),
        AppRoutes.map: (_) => const MapScreen(),
        AppRoutes.dashboard: (_) => const DashboardScreen(),
        AppRoutes.employeePortal: (_) => const EmployeePortalScreen(),
      },
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  @override
  void initState() {
    super.initState();
    // Restores the ResQNet backend session (stored tokens, one refresh if
    // needed; offline keeps an existing session). A failure here is never
    // fatal — it simply leaves the user signed out.
    unawaited(
      context.read<AuthService>().restoreBackendSession().then((_) {}, onError: (_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    const primary = ThemeService.primaryColor;
    // The ResQNet backend session is the only authority on sign-in state.
    final status = context.watch<AuthService>().backendSession.status;
    return authGateScreenFor(
      status,
      loading: Scaffold(body: Center(child: CircularProgressIndicator(color: primary))),
      signedIn: const HomeScreen(),
      signedOut: const LoginScreen(),
    );
  }
}

/// Which screen the auth gate shows for a backend session [status].
/// Resolving (unknown/restoring) shows [loading] so a signed-in user never
/// flashes the sign-in screen on cold start.
@visibleForTesting
Widget authGateScreenFor(
  BackendSessionStatus status, {
  required Widget loading,
  required Widget signedIn,
  required Widget signedOut,
}) {
  switch (status) {
    case BackendSessionStatus.unknown:
    case BackendSessionStatus.restoring:
      return loading;
    case BackendSessionStatus.authenticated:
      return signedIn;
    case BackendSessionStatus.unauthenticated:
      return signedOut;
  }
}
