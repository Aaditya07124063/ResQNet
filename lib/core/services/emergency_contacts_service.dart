import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class EmergencyContact {
  final String name;
  final String number;
  final String description;

  const EmergencyContact({
    required this.name,
    required this.number,
    required this.description,
  });
}

class EmergencyContactsService extends ChangeNotifier {
  List<EmergencyContact> _contacts = [];
  String _countryName = 'Unknown';
  bool _isLoading = false;

  List<EmergencyContact> get contacts => _contacts;
  String get countryName => _countryName;
  bool get isLoading => _isLoading;

  static const Map<String, List<EmergencyContact>> _countryContacts = {
    'IN': [
      EmergencyContact(name: 'Police', number: '100', description: 'National Police Emergency'),
      EmergencyContact(name: 'Ambulance', number: '102', description: 'Medical Emergency'),
      EmergencyContact(name: 'Fire', number: '101', description: 'Fire Department'),
      EmergencyContact(name: 'Disaster Management', number: '108', description: 'NDRF / State Disaster'),
      EmergencyContact(name: 'Women Helpline', number: '1091', description: 'Women in distress'),
      EmergencyContact(name: 'Child Helpline', number: '1098', description: 'Child emergency'),
    ],
    'NP': [
      EmergencyContact(name: 'Police', number: '100', description: 'Nepal Police'),
      EmergencyContact(name: 'Ambulance', number: '102', description: 'Medical Emergency'),
      EmergencyContact(name: 'Fire', number: '101', description: 'Fire Department'),
      EmergencyContact(name: 'Disaster Relief', number: '1144', description: 'Nepal Disaster Relief'),
      EmergencyContact(name: 'Armed Police', number: '103', description: 'Armed Police Force'),
    ],
    'US': [
      EmergencyContact(name: 'Emergency', number: '911', description: 'Police / Fire / Ambulance'),
      EmergencyContact(name: 'FEMA', number: '1-800-621-3362', description: 'Federal Emergency Management'),
      EmergencyContact(name: 'Poison Control', number: '1-800-222-1222', description: 'Poison Emergency'),
      EmergencyContact(name: 'Crisis Line', number: '988', description: 'Mental Health Crisis'),
    ],
    'GB': [
      EmergencyContact(name: 'Emergency', number: '999', description: 'Police / Fire / Ambulance'),
      EmergencyContact(name: 'Non-Emergency', number: '101', description: 'Non-urgent police'),
      EmergencyContact(name: 'NHS', number: '111', description: 'Medical advice'),
    ],
    'AU': [
      EmergencyContact(name: 'Emergency', number: '000', description: 'Police / Fire / Ambulance'),
      EmergencyContact(name: 'Police Non-Emergency', number: '131 444', description: 'Non-urgent police'),
      EmergencyContact(name: 'SES', number: '132 500', description: 'State Emergency Service'),
    ],
    'AE': [
      EmergencyContact(name: 'Police', number: '999', description: 'Dubai / UAE Police'),
      EmergencyContact(name: 'Ambulance', number: '998', description: 'Medical Emergency'),
      EmergencyContact(name: 'Fire', number: '997', description: 'Civil Defence'),
    ],
    'PK': [
      EmergencyContact(name: 'Police', number: '15', description: 'Pakistan Police'),
      EmergencyContact(name: 'Ambulance', number: '1122', description: 'Rescue / Ambulance'),
      EmergencyContact(name: 'Fire', number: '16', description: 'Fire Department'),
    ],
    'BD': [
      EmergencyContact(name: 'Police', number: '999', description: 'Bangladesh Police'),
      EmergencyContact(name: 'Fire', number: '9555555', description: 'Fire Service'),
      EmergencyContact(name: 'Ambulance', number: '199', description: 'Medical Emergency'),
    ],
    'DEFAULT': [
      EmergencyContact(name: 'Global Emergency', number: '112', description: 'International Emergency Number'),
      EmergencyContact(name: 'Alternative', number: '911', description: 'US-style emergency'),
    ],
  };

  String _detectCountryFromCoords(double lat, double lng) {
    if (lat >= 8.0 && lat <= 37.6 && lng >= 68.7 && lng <= 97.4) return 'IN';
    if (lat >= 26.3 && lat <= 30.5 && lng >= 80.0 && lng <= 88.2) return 'NP';
    if (lat >= 24.4 && lat <= 49.4 && lng >= -125.0 && lng <= -66.9) return 'US';
    if (lat >= 49.9 && lat <= 60.9 && lng >= -8.2 && lng <= 2.0) return 'GB';
    if (lat >= -43.6 && lat <= -10.0 && lng >= 113.3 && lng <= 153.6) return 'AU';
    if (lat >= 22.6 && lat <= 26.1 && lng >= 51.6 && lng <= 56.4) return 'AE';
    if (lat >= 23.6 && lat <= 37.1 && lng >= 60.9 && lng <= 77.8) return 'PK';
    if (lat >= 20.6 && lat <= 26.6 && lng >= 88.0 && lng <= 92.7) return 'BD';
    return 'DEFAULT';
  }

  static const Map<String, String> _countryNames = {
    'IN': 'India',
    'NP': 'Nepal',
    'US': 'United States',
    'GB': 'United Kingdom',
    'AU': 'Australia',
    'AE': 'UAE',
    'PK': 'Pakistan',
    'BD': 'Bangladesh',
    'DEFAULT': 'International',
  };

  Future<void> detectAndLoadContacts() async {
    _isLoading = true;
    notifyListeners();

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _loadDefault();
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _loadDefault();
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );

      final countryCode = _detectCountryFromCoords(
        position.latitude,
        position.longitude,
      );

      _countryName = _countryNames[countryCode] ?? 'International';
      _contacts = _countryContacts[countryCode] ?? _countryContacts['DEFAULT']!;
    } catch (e) {
      _loadDefault();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _loadDefault() {
    _countryName = 'International';
    _contacts = _countryContacts['DEFAULT']!;
    _isLoading = false;
    notifyListeners();
  }
}