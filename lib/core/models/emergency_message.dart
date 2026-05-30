enum EmergencyType { medical, fire, flood, rescue, trapped, general }
enum PriorityLevel { low, medium, high, critical }

class EmergencyMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final EmergencyType type;
  final PriorityLevel priority;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final bool isRelayed;
  final int hopCount;

  EmergencyMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.type,
    required this.priority,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.isRelayed = false,
    this.hopCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderName': senderName,
    'content': content,
    'type': type.name,
    'priority': priority.name,
    'timestamp': timestamp.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'isRelayed': isRelayed,
    'hopCount': hopCount,
  };

  factory EmergencyMessage.fromJson(Map<String, dynamic> json) =>
      EmergencyMessage(
        id: json['id'],
        senderId: json['senderId'],
        senderName: json['senderName'],
        content: json['content'],
        type: EmergencyType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => EmergencyType.general,
        ),
        priority: PriorityLevel.values.firstWhere(
          (e) => e.name == json['priority'],
          orElse: () => PriorityLevel.low,
        ),
        timestamp: DateTime.parse(json['timestamp']),
        latitude: json['latitude'],
        longitude: json['longitude'],
        isRelayed: json['isRelayed'] ?? false,
        hopCount: json['hopCount'] ?? 0,
      );

  EmergencyMessage copyWith({bool? isRelayed, int? hopCount}) =>
      EmergencyMessage(
        id: id,
        senderId: senderId,
        senderName: senderName,
        content: content,
        type: type,
        priority: priority,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        isRelayed: isRelayed ?? this.isRelayed,
        hopCount: hopCount ?? this.hopCount,
      );
}
