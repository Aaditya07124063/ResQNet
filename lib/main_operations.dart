import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'features/operations/ops_theme.dart';
import 'core/employee/employee_session.dart';
import 'core/employee/operations_api.dart';
import 'features/employee/employee_portal_screen.dart';

/// Stand-alone entry point for the operations (EOC) portal, for desktop,
/// laptop and tablet browsers:
///
///   flutter build web -t lib/main_operations.dart --dart-define=API_ENV=production
///
/// It contains only the staff portal — the same employee sign-in, session
/// and API client the mobile app's portal uses — and none of the civilian
/// app (no mesh, sensors or civilian account).
void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => EmployeeSession()),
        Provider(create: (_) => OperationsApi()),
      ],
      child: const OperationsApp(),
    ),
  );
}

class OperationsApp extends StatelessWidget {
  const OperationsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ResQNet Operations',
      debugShowCheckedModeBanner: false,
      theme: operationsTheme(),
      home: const EmployeePortalScreen(),
    );
  }
}
