/// A ResQNet chat message — transport-independent (Section 21: the same
/// shape is meant to work whether it travels over the authenticated
/// WebSocket/HTTPS path, implemented here, or in the future over the
/// existing mesh transport — see mesh_service.dart's own EmergencyMessage
/// for the precedent this mirrors).
enum MessageType { text, location }

/// Client-side send/delivery lifecycle — richer than the two
/// backend-persisted states (`message_status.status`: sent/delivered/read)
/// because it also has to represent "not sent to the server yet"
/// (pending, while offline) and "the server rejected/couldn't reach it"
/// (failed), which are meaningful to show in the UI but have no row in
/// Postgres at all until the send actually succeeds.
enum MessageDeliveryState { pending, sent, delivered, read, failed }

class Message {
  final String id;
  final String conversationId;
  final String senderUserId;
  final String clientMessageId;
  final MessageType type;
  final String? body;
  final double? latitude;
  final double? longitude;
  final double? locationAccuracyM;
  final DateTime clientCreatedAt;
  final DateTime? serverReceivedAt;
  final MessageDeliveryState deliveryState;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderUserId,
    required this.clientMessageId,
    required this.type,
    this.body,
    this.latitude,
    this.longitude,
    this.locationAccuracyM,
    required this.clientCreatedAt,
    this.serverReceivedAt,
    this.deliveryState = MessageDeliveryState.sent,
  });

  Message copyWith({String? id, DateTime? serverReceivedAt, MessageDeliveryState? deliveryState}) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId,
      senderUserId: senderUserId,
      clientMessageId: clientMessageId,
      type: type,
      body: body,
      latitude: latitude,
      longitude: longitude,
      locationAccuracyM: locationAccuracyM,
      clientCreatedAt: clientCreatedAt,
      serverReceivedAt: serverReceivedAt ?? this.serverReceivedAt,
      deliveryState: deliveryState ?? this.deliveryState,
    );
  }

  factory Message.fromJson(Map<String, dynamic> json, {MessageDeliveryState deliveryState = MessageDeliveryState.sent}) {
    final typeStr = json['messageType'] as String? ?? 'text';
    return Message(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      senderUserId: json['senderUserId'] as String,
      clientMessageId: json['clientMessageId'] as String,
      type: typeStr == 'location' ? MessageType.location : MessageType.text,
      body: json['body'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationAccuracyM: (json['locationAccuracyM'] as num?)?.toDouble(),
      clientCreatedAt: DateTime.parse(json['clientCreatedAt'] as String),
      serverReceivedAt:
          json['serverReceivedAt'] != null ? DateTime.parse(json['serverReceivedAt'] as String) : null,
      deliveryState: deliveryState,
    );
  }

  /// The outgoing wire shape for `POST /conversations/:id/messages` — a
  /// discriminated shape matching communicationSchemas.ts's
  /// sendMessageSchema exactly (never sends latitude/longitude on a text
  /// message or a body on a location message).
  Map<String, dynamic> toSendJson() {
    final base = {
      'messageType': type == MessageType.location ? 'location' : 'text',
      'clientMessageId': clientMessageId,
      'clientCreatedAt': clientCreatedAt.toIso8601String(),
    };
    if (type == MessageType.location) {
      return {
        ...base,
        'latitude': latitude,
        'longitude': longitude,
        if (locationAccuracyM != null) 'locationAccuracyM': locationAccuracyM,
      };
    }
    return {...base, 'body': body};
  }
}
