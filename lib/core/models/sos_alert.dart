enum SosStatus { active, acknowledged, resolved }

enum SosCategory { medical, fire, flood, earthquake, rescue, trapped, general }

class SosAlert {
  final String id;
  final String userId;
  final String userName;
  final SosCategory category;
  final String message;
  final double? latitude;
  final double? longitude;
  final DateTime timestamp;
  SosStatus status;

  SosAlert({
    required this.id,
    required this.userId,
    required this.userName,
    required this.category,
    required this.message,
    this.latitude,
    this.longitude,
    required this.timestamp,
    this.status = SosStatus.active,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'category': category.name,
        'message': message,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.name,
      };

  factory SosAlert.fromJson(Map<String, dynamic> json) => SosAlert(
        id: json['id'],
        userId: json['userId'],
        userName: json['userName'],
        category: SosCategory.values.firstWhere(
            (e) => e.name == json['category'],
            orElse: () => SosCategory.general),
        message: json['message'],
        latitude: json['latitude']?.toDouble(),
        longitude: json['longitude']?.toDouble(),
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        status: SosStatus.values.firstWhere(
            (e) => e.name == json['status'],
            orElse: () => SosStatus.active),
      );
}