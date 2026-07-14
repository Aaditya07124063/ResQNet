import 'package:flutter/material.dart';

enum EmergencyType {
  medical,
  fire,
  flood,
  earthquake,
  trapped,
  rescue,
  general,
}

enum PriorityLevel {
  critical,
  high,
  medium,
  low,
}

class EmergencyMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String message;
  final EmergencyType type;
  final PriorityLevel priority;
  final double? latitude;
  final double? longitude;
  final DateTime timestamp;
  final int hopCount;
  final bool isRelayed;
  final String? bloodGroup;
  final String? allergies;
  final String? medications;
  final int? batteryLevel;

  EmergencyMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.message,
    required this.type,
    required this.priority,
    this.latitude,
    this.longitude,
    required this.timestamp,
    this.hopCount = 0,
    this.isRelayed = false,
    this.bloodGroup,
    this.allergies,
    this.medications,
    this.batteryLevel,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'senderId': senderId,
        'senderName': senderName,
        'message': message,
        'type': type.name,
        'priority': priority.name,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'hopCount': hopCount,
        'isRelayed': isRelayed,
        'bloodGroup': bloodGroup,
        'allergies': allergies,
        'medications': medications,
        'batteryLevel': batteryLevel,
      };

  factory EmergencyMessage.fromJson(Map<String, dynamic> json) =>
      EmergencyMessage(
        id: json['id'],
        senderId: json['senderId'],
        senderName: json['senderName'],
        message: json['message'],
        type: EmergencyType.values.firstWhere(
            (e) => e.name == json['type'],
            orElse: () => EmergencyType.general),
        priority: PriorityLevel.values.firstWhere(
            (e) => e.name == json['priority'],
            orElse: () => PriorityLevel.low),
        latitude: json['latitude']?.toDouble(),
        longitude: json['longitude']?.toDouble(),
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        hopCount: json['hopCount'] ?? 0,
        isRelayed: json['isRelayed'] ?? false,
        bloodGroup: json['bloodGroup'],
        allergies: json['allergies'],
        medications: json['medications'],
        batteryLevel: json['batteryLevel'],
      );

  EmergencyMessage copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? message,
    EmergencyType? type,
    PriorityLevel? priority,
    double? latitude,
    double? longitude,
    DateTime? timestamp,
    int? hopCount,
    bool? isRelayed,
    String? bloodGroup,
    String? allergies,
    String? medications,
    int? batteryLevel,
  }) =>
      EmergencyMessage(
        id: id ?? this.id,
        senderId: senderId ?? this.senderId,
        senderName: senderName ?? this.senderName,
        message: message ?? this.message,
        type: type ?? this.type,
        priority: priority ?? this.priority,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        timestamp: timestamp ?? this.timestamp,
        hopCount: hopCount ?? this.hopCount,
        isRelayed: isRelayed ?? this.isRelayed,
        bloodGroup: bloodGroup ?? this.bloodGroup,
        allergies: allergies ?? this.allergies,
        medications: medications ?? this.medications,
        batteryLevel: batteryLevel ?? this.batteryLevel,
      );

  Color get priorityColor {
    switch (priority) {
      case PriorityLevel.critical:
        return const Color(0xFFD32F2F);
      case PriorityLevel.high:
        return const Color(0xFFFF6F00);
      case PriorityLevel.medium:
        return const Color(0xFFF9A825);
      case PriorityLevel.low:
        return const Color(0xFF2E7D32);
    }
  }

  IconData get typeIcon {
    switch (type) {
      case EmergencyType.medical:
        return Icons.local_hospital;
      case EmergencyType.fire:
        return Icons.local_fire_department;
      case EmergencyType.flood:
        return Icons.water;
      case EmergencyType.earthquake:
        return Icons.terrain;
      case EmergencyType.trapped:
        return Icons.person_pin_circle;
      case EmergencyType.rescue:
        return Icons.emergency;
      case EmergencyType.general:
        return Icons.warning;
    }
  }
}