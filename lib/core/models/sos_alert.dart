import 'emergency_message.dart';

enum SosStatus { sent, received, acknowledged, resolved }
enum SosCategory { medical, fire, flood, rescue, trapped, other }

class SosAlert {
  final String id;
  final String userId;
  final SosCategory category;
  final String message;
  final double? latitude;
  final double? longitude;
  final DateTime timestamp;
  final PriorityLevel priority;
  SosStatus status;

  SosAlert({
    required this.id,
    required this.userId,
    required this.category,
    required this.message,
    required this.timestamp,
    required this.priority,
    this.latitude,
    this.longitude,
    this.status = SosStatus.sent,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'category': category.name,
    'message': message,
    'latitude': latitude,
    'longitude': longitude,
    'timestamp': timestamp.toIso8601String(),
    'priority': priority.name,
    'status': status.name,
  };
}
