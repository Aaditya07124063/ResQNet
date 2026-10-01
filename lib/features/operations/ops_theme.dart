import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

/// Fixed dark palette for the operations portal. The mobile app switches
/// AppColors between light and dark at runtime; the portal keeps one
/// high-contrast scheme so text and controls always meet WCAG AA.
abstract final class OpsColors {
  static Color get background => const Color(0xFF101418);
  static Color get surface => const Color(0xFF181D23);
  static Color get card => const Color(0xFF20262E);
  static Color get text => const Color(0xFFF2F4F7);
  static Color get textMuted => const Color(0xFFB9C1CC);
}

ThemeData operationsTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accentBlue,
    brightness: Brightness.dark,
  ).copyWith(surface: OpsColors.surface, onSurface: OpsColors.text, onSurfaceVariant: OpsColors.textMuted);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: OpsColors.background,
    cardColor: OpsColors.card,
    // Standard density everywhere (desktop defaults to compact, which
    // shrinks tap targets below 48 px).
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    focusColor: scheme.primary.withValues(alpha: 0.35),
  );
}

/// Applies the operations theme to a subtree (pages pushed on the app's
/// navigator, and the dialogs they open, inherit it).
class OpsThemed extends StatelessWidget {
  const OpsThemed({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(data: operationsTheme(), child: child);
}
