import 'package:flutter/material.dart';

/// The app's color palette. Every screen reads these instead of
/// Theme.of(context) directly, so this class itself has to be the thing
/// that changes when ThemeService toggles dark/light — that's what
/// [applyBrightness] does. Only the neutral surface/text colors actually
/// differ between the two modes; brand/status accent colors (red for
/// emergency, green for safe, etc.) stay constant so they keep reading
/// clearly against either background.
class AppColors {
  // --- Brand/status accents — same in both themes ---
  static const Color emergencyRed = Color(0xFFD32F2F);
  static const Color emergencyOrange = Color(0xFFFF6F00);
  static const Color emergencyYellow = Color(0xFFF9A825);
  static const Color emergencyGreen = Color(0xFF2E7D32);
  static const Color accentBlue = Color(0xFF1565C0);
  static const Color connectedGreen = Color(0xFF4CAF50);
  static const Color primaryOrange = Color(0xFFE65100);
  static const Color warningAmber = Color(0xFFF9A825);
  static const Color safeGreen = Color(0xFF4CAF50);
  static const Color infoBlue = Color(0xFF1565C0);
  static const Color criticalRed = Color(0xFFD32F2F);
  static const Color highOrange = Color(0xFFFF6F00);
  static const Color mediumYellow = Color(0xFFF9A825);

  // --- Dark-mode neutral values (the app's original/default look) ---
  static const Color _backgroundDarkMode = Color(0xFF121212);
  static const Color _surfaceDarkMode = Color(0xFF1E1E1E);
  static const Color _cardDarkMode = Color(0xFF2A2A2A);
  static const Color _textPrimaryDarkMode = Color(0xFFFFFFFF);
  static const Color _textSecondaryDarkMode = Color(0xFFB0B0B0);
  static const Color _disconnectedGreyDarkMode = Color(0xFF616161);

  // --- Light-mode neutral values ---
  static const Color _backgroundLightMode = Color(0xFFF5F5F5);
  static const Color _surfaceLightMode = Color(0xFFFFFFFF);
  static const Color _cardLightMode = Color(0xFFFFFFFF);
  static const Color _textPrimaryLightMode = Color(0xFF212121);
  static const Color _textSecondaryLightMode = Color(0xFF616161);
  static const Color _disconnectedGreyLightMode = Color(0xFF9E9E9E);

  // Mutable — reassigned by applyBrightness(), which is why these can't
  // stay `const`. This is the one place in the app that's a runtime
  // global; every screen reading AppColors.backgroundDark etc. picks up
  // whichever mode is currently active without needing its own
  // Theme.of(context) plumbing.
  static Color backgroundDark = _backgroundDarkMode;
  static Color surfaceDark = _surfaceDarkMode;
  static Color cardDark = _cardDarkMode;
  static Color textPrimary = _textPrimaryDarkMode;
  static Color textSecondary = _textSecondaryDarkMode;
  static Color disconnectedGrey = _disconnectedGreyDarkMode;
  static Color lowGrey = _disconnectedGreyDarkMode;

  /// Called by ThemeService on load and on every toggle — swaps every
  /// neutral color to match. Must run (and the app must rebuild) before
  /// this has any visible effect, which is why ThemeService calls this
  /// before notifyListeners(), not after.
  static void applyBrightness(bool isDark) {
    backgroundDark = isDark ? _backgroundDarkMode : _backgroundLightMode;
    surfaceDark = isDark ? _surfaceDarkMode : _surfaceLightMode;
    cardDark = isDark ? _cardDarkMode : _cardLightMode;
    textPrimary = isDark ? _textPrimaryDarkMode : _textPrimaryLightMode;
    textSecondary = isDark ? _textSecondaryDarkMode : _textSecondaryLightMode;
    disconnectedGrey =
        isDark ? _disconnectedGreyDarkMode : _disconnectedGreyLightMode;
    lowGrey = disconnectedGrey;
  }
}
