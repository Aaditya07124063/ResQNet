import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/models/message.dart';

void main() {
  group('Message.toSendJson', () {
    test('a text message sends body but never latitude/longitude', () {
      final message = Message(
        id: 'local-1',
        conversationId: 'conv-1',
        senderUserId: '',
        clientMessageId: 'client-1',
        type: MessageType.text,
        body: 'hello',
        clientCreatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );

      final json = message.toSendJson();

      expect(json['messageType'], 'text');
      expect(json['body'], 'hello');
      expect(json.containsKey('latitude'), isFalse);
      expect(json.containsKey('longitude'), isFalse);
    });

    test('a location message sends coordinates but never a body', () {
      final message = Message(
        id: 'local-2',
        conversationId: 'conv-1',
        senderUserId: '',
        clientMessageId: 'client-2',
        type: MessageType.location,
        latitude: 27.7172,
        longitude: 85.324,
        locationAccuracyM: 10,
        clientCreatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );

      final json = message.toSendJson();

      expect(json['messageType'], 'location');
      expect(json['latitude'], 27.7172);
      expect(json['longitude'], 85.324);
      expect(json.containsKey('body'), isFalse);
    });

    test('always includes the same clientMessageId — idempotency depends on this never changing across retries', () {
      final message = Message(
        id: 'local-3',
        conversationId: 'conv-1',
        senderUserId: '',
        clientMessageId: 'stable-client-id',
        type: MessageType.text,
        body: 'retry me',
        clientCreatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );

      expect(message.toSendJson()['clientMessageId'], 'stable-client-id');
      // Calling it again (simulating a retry) must produce the identical id.
      expect(message.toSendJson()['clientMessageId'], 'stable-client-id');
    });
  });

  group('Message.fromJson', () {
    test('parses a server-confirmed text message', () {
      final message = Message.fromJson({
        'id': 'server-1',
        'conversationId': 'conv-1',
        'senderUserId': 'user-2',
        'clientMessageId': 'client-1',
        'messageType': 'text',
        'body': 'hi',
        'clientCreatedAt': '2026-01-01T00:00:00.000Z',
        'serverReceivedAt': '2026-01-01T00:00:01.000Z',
      });

      expect(message.id, 'server-1');
      expect(message.type, MessageType.text);
      expect(message.body, 'hi');
      expect(message.deliveryState, MessageDeliveryState.sent);
    });

    test('parses a server-confirmed location message', () {
      final message = Message.fromJson({
        'id': 'server-2',
        'conversationId': 'conv-1',
        'senderUserId': 'user-2',
        'clientMessageId': 'client-2',
        'messageType': 'location',
        'latitude': 27.7172,
        'longitude': 85.324,
        'clientCreatedAt': '2026-01-01T00:00:00.000Z',
      });

      expect(message.type, MessageType.location);
      expect(message.latitude, 27.7172);
      expect(message.body, isNull);
    });
  });
}
