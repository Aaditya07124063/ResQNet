import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_colors.dart';

class ThemeService extends ChangeNotifier {
  static const _darkKey = 'is_dark_mode';

  static const Color primaryColor = Color(0xFFD32F2F);

  bool _isDarkMode = true;

  bool get isDarkMode => _isDarkMode;

  ThemeService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_darkKey) ?? true;
    // AppColors' actual values must be updated before the first
    // notifyListeners() — otherwise the initial build reads stale
    // (default dark) colors even when the saved preference is light.
    AppColors.applyBrightness(_isDarkMode);
    notifyListeners();
  }

  Future<void> toggleDarkMode() async {
    _isDarkMode = !_isDarkMode;
    AppColors.applyBrightness(_isDarkMode);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkKey, _isDarkMode);
  }
}