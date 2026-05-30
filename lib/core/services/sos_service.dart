import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/sos_alert.dart';
import '../models/emergency_message.dart';
import '../services/ai_service.dart';
import '../services/location_service.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';

class SosService extends ChangeNotifier {
  final AiService _aiService;
  final LocationService _locationService;
  final FirebaseService _firebaseService = FirebaseService();
  final NotificationService _notificationService = NotificationService();
  final _uuid = const Uuid();

  final List<SosAlert> _alerts = [];
  bool _sosActive = false;

  SosService(this._aiService, this._locationService);

  List<SosAlert> get alerts => List.unmodifiable(_alerts);
  bool get sosActive => _sosActive;

  Future<SosAlert> triggerSos({
    required String userId,
    required String userName,
    required SosCategory category,
    required String message,
  }) async {
    final position = await _locationService.getCurrentLocation();
    final alert = SosAlert(
      id: _uuid.v4(),
      userId: userId,
      userName: userName,
      category: category,
      message: message,
      latitude: position?.latitude,
      longitude: position?.longitude,
      timestamp: DateTime.now(),
      status: SosStatus.active,
    );

    _alerts.insert(0, alert);
    _sosActive = true;
    notifyListeners();

    await _firebaseService.uploadSosAlert(alert);
    await _notificationService.broadcastSosNotification(alert);

    return alert;
  }

  EmergencyMessage sosToBroadcastMessage(SosAlert alert, String senderName) {
    final type = _aiService.classifyEmergency(alert.message);
    final priority = _aiService.assessPriority(alert.message, type);

    return EmergencyMessage(
      id: alert.id,
      senderId: alert.userId,
      senderName: senderName,
      message: alert.message,
      type: type,
      priority: priority,
      latitude: alert.latitude,
      longitude: alert.longitude,
      timestamp: alert.timestamp,
    );
  }

  void cancelSos(String alertId) {
    final idx = _alerts.indexWhere((a) => a.id == alertId);
    if (idx != -1) {
      _alerts[idx].status = SosStatus.resolved;
      _sosActive = false;
      notifyListeners();
    }
  }
}