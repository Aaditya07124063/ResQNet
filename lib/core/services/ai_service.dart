import '../models/emergency_message.dart';

class AiService {
  static const List<String> _criticalKeywords = [
    'trapped', 'dying', 'critical', 'unconscious', 'bleeding heavily',
    'child trapped', 'building collapsed', 'cannot breathe', 'drowning',
  ];
  static const List<String> _highKeywords = [
    'injured', 'stuck', 'missing', 'smoke', 'water rising', 'need rescue',
    'fire spreading', 'hurt', 'accident', 'help', 'emergency',
  ];
  static const List<String> _mediumKeywords = [
    'need food', 'need water', 'shelter needed', 'lost', 'stranded',
    'no signal', 'need medicine', 'sick',
  ];

  PriorityLevel prioritize(String text) {
    final lower = text.toLowerCase();
    if (_criticalKeywords.any((k) => lower.contains(k))) {
      return PriorityLevel.critical;
    }
    if (_highKeywords.any((k) => lower.contains(k))) {
      return PriorityLevel.high;
    }
    if (_mediumKeywords.any((k) => lower.contains(k))) {
      return PriorityLevel.medium;
    }
    return PriorityLevel.low;
  }

  EmergencyType classify(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('fire') || lower.contains('burn')) {
      return EmergencyType.fire;
    }
    if (lower.contains('flood') || lower.contains('water') || lower.contains('drown')) {
      return EmergencyType.flood;
    }
    if (lower.contains('medical') || lower.contains('bleed') ||
        lower.contains('heart') || lower.contains('breath')) {
      return EmergencyType.medical;
    }
    if (lower.contains('trap') || lower.contains('stuck') || lower.contains('collapse')) {
      return EmergencyType.trapped;
    }
    if (lower.contains('rescue') || lower.contains('help') || lower.contains('missing')) {
      return EmergencyType.rescue;
    }
    return EmergencyType.general;
  }
}
