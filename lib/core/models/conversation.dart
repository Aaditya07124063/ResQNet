import 'message.dart';

class ConversationLastMessage {
  final String id;
  final MessageType messageType;
  final String? body;
  final String senderUserId;
  final DateTime createdAt;

  const ConversationLastMessage({
    required this.id,
    required this.messageType,
    required this.body,
    required this.senderUserId,
    required this.createdAt,
  });

  factory ConversationLastMessage.fromJson(Map<String, dynamic> json) {
    return ConversationLastMessage(
      id: json['id'] as String,
      messageType: (json['messageType'] as String) == 'location' ? MessageType.location : MessageType.text,
      body: json['body'] as String?,
      senderUserId: json['senderUserId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class ConversationSummary {
  final String id;
  final String? otherParticipantId;
  final String? otherParticipantName;
  final ConversationLastMessage? lastMessage;
  final int unreadCount;
  final DateTime updatedAt;

  const ConversationSummary({
    required this.id,
    required this.otherParticipantId,
    required this.otherParticipantName,
    required this.lastMessage,
    required this.unreadCount,
    required this.updatedAt,
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    final other = json['otherParticipant'] as Map<String, dynamic>?;
    final lastMessageJson = json['lastMessage'] as Map<String, dynamic>?;
    return ConversationSummary(
      id: json['id'] as String,
      otherParticipantId: other?['id'] as String?,
      otherParticipantName: other?['displayName'] as String?,
      lastMessage: lastMessageJson != null ? ConversationLastMessage.fromJson(lastMessageJson) : null,
      unreadCount: json['unreadCount'] as int? ?? 0,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}
