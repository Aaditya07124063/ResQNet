import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/emergency_message.dart';
import '../models/sos_alert.dart';
import 'location_service.dart';
import 'ai_service.dart';

class SosService extends ChangeNotifier {
  final List<SosAlert> _alerts = [];
  List<SosAlert> get alerts => List.unmodifiable(_alerts);

  Future<SosAlert> createAlert({
    required SosCategory category,
    required String message,
    required LocationService locationService,
    required AiService aiService,
  }) async {
    final position = await locationService.getCurrentPosition();
    final priority = aiService.prioritize(message);
    final alert = SosAlert(
      id: const Uuid().v4(),
      userId: 'user_local',
      category: category,
      message: message,
      latitude: position?.latitude,
      longitude: position?.longitude,
      timestamp: DateTime.now(),
      priority: priority,
    );
    _alerts.add(alert);
    notifyListeners();
    return alert;
  }

  EmergencyMessage alertToMessage(SosAlert alert) => EmergencyMessage(
        id: alert.id,
        senderId: alert.userId,
        senderName: 'Me',
        content: '[SOS] ${alert.category.name.toUpperCase()}: ${alert.message}',
        type: _categoryToType(alert.category),
        priority: alert.priority,
        timestamp: alert.timestamp,
        latitude: alert.latitude,
        longitude: alert.longitude,
      );

  EmergencyType _categoryToType(SosCategory cat) {
    switch (cat) {
      case SosCategory.medical: return EmergencyType.medical;
      case SosCategory.fire: return EmergencyType.fire;
      case SosCategory.flood: return EmergencyType.flood;
      case SosCategory.rescue: return EmergencyType.rescue;
      case SosCategory.trapped: return EmergencyType.trapped;
      case SosCategory.other: return EmergencyType.general;
    }
  }
}
