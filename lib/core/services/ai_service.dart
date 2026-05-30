import 'package:flutter/foundation.dart';
import '../models/emergency_message.dart';

class AiService extends ChangeNotifier {
  static const Map<EmergencyType, List<String>> _keywords = {
    EmergencyType.medical: [
      'heart', 'blood', 'injury', 'hospital', 'pain',
      'unconscious', 'breathing', 'medical', 'doctor', 'ambulance', 'wounded',
    ],
    EmergencyType.fire: [
      'fire', 'burning', 'smoke', 'flame', 'blaze', 'explosion',
    ],
    EmergencyType.flood: [
      'flood', 'water', 'drowning', 'submerged', 'rain', 'river', 'overflow',
    ],
    EmergencyType.earthquake: [
      'earthquake', 'tremor', 'quake', 'collapse', 'rubble', 'building fell',
    ],
    EmergencyType.rescue: [
      'trapped', 'stuck', 'rescue', 'help', 'missing', 'lost',
    ],
  };

  static const Map<PriorityLevel, List<String>> _priorityKeywords = {
    PriorityLevel.critical: [
      'dying', 'critical', 'urgent', 'immediate', 'life threatening',
      'unconscious', 'not breathing',
    ],
    PriorityLevel.high: [
      'serious', 'severe', 'major', 'bad', 'dangerous', 'emergency',
    ],
    PriorityLevel.medium: [
      'injured', 'hurt', 'trapped', 'need help', 'assistance',
    ],
  };

  EmergencyType classifyEmergency(String message) {
    final lower = message.toLowerCase();
    for (final entry in _keywords.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) return entry.key;
      }
    }
    return EmergencyType.general;
  }

  PriorityLevel assessPriority(String message, EmergencyType type) {
    final lower = message.toLowerCase();
    for (final entry in _priorityKeywords.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) return entry.key;
      }
    }
    if (type == EmergencyType.medical || type == EmergencyType.fire) {
      return PriorityLevel.high;
    }
    return PriorityLevel.medium;
  }

  String generateSuggestion(EmergencyType type) {
    switch (type) {
      case EmergencyType.medical:
        return 'Keep patient calm. Do not move if spinal injury suspected.';
      case EmergencyType.fire:
        return 'Stay low, crawl to exit. Do not use elevators.';
      case EmergencyType.flood:
        return 'Move to higher ground immediately.';
      case EmergencyType.earthquake:
        return 'Drop, Cover, Hold On. Stay away from windows.';
      case EmergencyType.rescue:
        return 'Stay visible. Use whistle to signal rescuers.';
      case EmergencyType.general:
        return 'Stay calm. Follow official instructions.';
    }
  }
}