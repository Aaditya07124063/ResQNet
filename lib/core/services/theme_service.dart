import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static const _colorKey = 'theme_color';
  static const _darkKey = 'is_dark_mode';

  Color _primaryColor = const Color(0xFFD32F2F);
  bool _isDarkMode = true;

  Color get primaryColor => _primaryColor;
  bool get isDarkMode => _isDarkMode;

  static const Map<String, Color> availableThemes = {
    'Emergency Red': Color(0xFFD32F2F),
    'Rescue Orange': Color(0xFFE65100),
    'Alert Blue': Color(0xFF1565C0),
    'Safe Green': Color(0xFF2E7D32),
    'Warning Purple': Color(0xFF6A1B9A),
    'Night Teal': Color(0xFF00695C),
  };

  ThemeService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_colorKey);
    if (colorValue != null) _primaryColor = Color(colorValue);
    _isDarkMode = prefs.getBool(_darkKey) ?? true;
    notifyListeners();
  }

  Future<void> setColor(Color color) async {
    _primaryColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_colorKey, color.value);
  }

  Future<void> toggleDarkMode() async {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkKey, _isDarkMode);
  }
}