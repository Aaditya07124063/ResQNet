import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/constants/app_routes.dart';
import 'core/network/backend_session_controller.dart';
import 'core/services/theme_service.dart';
import 'features/auth/auth_service.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
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
    // Phase 4B: kick off backend-session restoration in parallel with
    // Firebase's own state, purely so it's tracked (AuthService.backendSession)
    // for Phase 4C/4D to consume later. Deliberately NOT awaited and NOT
    // used to decide what this widget renders below — Firebase's
    // authStateChanges() remains the sole gate until Google login is cut
    // over. A failure here must never affect the (Firebase-driven) auth
    // flow, hence the broad catch.
    unawaited(
      context.read<AuthService>().restoreBackendSession().then((_) {}, onError: (_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    const primary = ThemeService.primaryColor;
    // Phase 4C: the backend Google-login path is now authoritative for
    // Google sign-in, alongside Firebase (still authoritative for phone
    // login, until Phase 9). A user is considered signed in if EITHER
    // session is valid — a backend-authenticated Google user must never
    // be bounced back to LoginScreen just because FirebaseAuth.currentUser
    // is null, since backend Google login deliberately does not create a
    // Firebase session at all.
    final backendStatus = context.watch<AuthService>().backendSession.status;
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snapshot) {
        final firebaseStillResolving =
            snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData;
        // Wait for the startup restoreBackendSession() call (kicked off in
        // initState) to finish at least once before deciding — otherwise a
        // Google-only user would flash LoginScreen for a frame on every
        // cold start before their restored backend session is observed.
        final backendStillResolving =
            backendStatus == BackendSessionStatus.unknown ||
                backendStatus == BackendSessionStatus.restoring;
        if (firebaseStillResolving || backendStillResolving) {
          return Scaffold(
            body:
                Center(child: CircularProgressIndicator(color: primary)),
          );
        }
        final firebaseSignedIn = snapshot.hasData && snapshot.data != null;
        final backendSignedIn =
            backendStatus == BackendSessionStatus.authenticated;
        if (firebaseSignedIn || backendSignedIn) {
          return const HomeScreen();
        }
        return const LoginScreen();
      },
    );
  }
}