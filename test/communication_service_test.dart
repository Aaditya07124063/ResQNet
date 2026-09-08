import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/models/message.dart';
import 'package:resqnet/core/services/communication_service.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    await TokenStorage.instance.save(accessToken: 'access-1', refreshToken: 'refresh-1');
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  group('sendText', () {
    test('the message is visible locally (pending) immediately, before the network call resolves', () async {
      final completer = Completer<void>();
      final fake = FakeHttpClient((request) async {
        await completer.future; // never resolves during this test — send stays in flight
        return jsonStreamedResponse(201, {'message': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      // Deliberately not awaited — sendText() must make the message
      // visible synchronously-ish (via the outbox) without waiting on the
      // network call it kicks off.
      final future = service.sendText('conv-1', 'hello');
      await Future<void>.delayed(Duration.zero);

      final messages = service.messagesFor('conv-1');
      expect(messages, hasLength(1));
      expect(messages.first.deliveryState, MessageDeliveryState.pending);
      expect(messages.first.body, 'hello');

      completer.complete();
      await future;
    });

    test('on success, the pending message is replaced by the server-confirmed one', () async {
      final fake = FakeHttpClient((request) async {
        final body = jsonDecode(request is http.Request ? request.body : '{}') as Map<String, dynamic>;
        return jsonStreamedResponse(201, {
          'message': {
            'id': 'server-msg-1',
            'conversationId': 'conv-1',
            'senderUserId': 'me',
            'clientMessageId': body['clientMessageId'],
            'messageType': 'text',
            'body': 'hello',
            'clientCreatedAt': DateTime.now().toIso8601String(),
            'serverReceivedAt': DateTime.now().toIso8601String(),
          },
        });
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello');

      final messages = service.messagesFor('conv-1');
      expect(messages, hasLength(1));
      expect(messages.first.id, 'server-msg-1');
      expect(messages.first.deliveryState, MessageDeliveryState.sent);
    });

    test('sends the correct request shape: POST to the conversation, with a text-only body', () async {
      late Map<String, dynamic> sentBody;
      final fake = FakeHttpClient((request) async {
        sentBody = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        return jsonStreamedResponse(201, {
          'message': {
            'id': 'server-msg-1',
            'conversationId': 'conv-1',
            'senderUserId': 'me',
            'clientMessageId': sentBody['clientMessageId'],
            'messageType': 'text',
            'body': 'hello',
            'clientCreatedAt': DateTime.now().toIso8601String(),
          },
        });
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello');

      expect(fake.requests, hasLength(1));
      expect(fake.requests.first.url.path, '/api/v1/conversations/conv-1/messages');
      expect(sentBody['messageType'], 'text');
      expect(sentBody.containsKey('latitude'), isFalse);
    });

    test('on a network failure, the message stays pending in the outbox rather than being lost', () async {
      final fake = FakeHttpClient((request) async {
        throw Exception('simulated network failure');
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello');

      final messages = service.messagesFor('conv-1');
      expect(messages, hasLength(1));
      expect(messages.first.deliveryState, MessageDeliveryState.pending);
    });

    test('on a network failure, the pending message is persisted to disk (survives an app restart)', () async {
      final fake = FakeHttpClient((request) async {
        throw Exception('simulated network failure');
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('resqnet_pending_messages_v1');
      expect(raw, isNotNull);
      final stored = jsonDecode(raw!) as List;
      expect(stored, hasLength(1));
      expect(stored.first['body'], 'hello');
    });

    test('on a transient backend failure (500), the message stays pending — not marked failed', () async {
      // Regression test (sync audit, FINAL GAP CLOSURE item 7): a 500
      // reached us but says nothing about this message's content being
      // wrong — must be retried like a network failure, not given up on.
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(500, {
            'error': {'code': 'INTERNAL_ERROR', 'message': 'temporary failure'},
          }));
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello');

      final messages = service.messagesFor('conv-1');
      expect(messages, hasLength(1));
      expect(messages.first.deliveryState, MessageDeliveryState.pending);
    });

    test('on a genuine rejection (403), the message is marked failed, not retried', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(403, {
            'error': {'code': 'FORBIDDEN', 'message': 'no longer a participant'},
          }));
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello');

      final messages = service.messagesFor('conv-1');
      expect(messages, hasLength(1));
      expect(messages.first.deliveryState, MessageDeliveryState.failed);
    });

    test('a retried send after the network returns is idempotent — same clientMessageId as the original attempt', () async {
      String? firstClientMessageId;
      var attempt = 0;
      final fake = FakeHttpClient((request) async {
        attempt++;
        final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        if (attempt == 1) {
          firstClientMessageId = body['clientMessageId'] as String;
          throw Exception('simulated network failure');
        }
        expect(body['clientMessageId'], firstClientMessageId);
        return jsonStreamedResponse(201, {
          'message': {
            'id': 'server-msg-1',
            'conversationId': 'conv-1',
            'senderUserId': 'me',
            'clientMessageId': body['clientMessageId'],
            'messageType': 'text',
            'body': 'hello',
            'clientCreatedAt': DateTime.now().toIso8601String(),
          },
        });
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendText('conv-1', 'hello'); // fails, stays pending
      expect(service.messagesFor('conv-1').first.deliveryState, MessageDeliveryState.pending);

      await service.retryPendingSends(); // succeeds

      expect(service.messagesFor('conv-1'), hasLength(1));
      expect(service.messagesFor('conv-1').first.deliveryState, MessageDeliveryState.sent);
      expect(attempt, 2);
    });
  });

  group('sendLocation', () {
    test('sends coordinates and never a text body', () async {
      late Map<String, dynamic> sentBody;
      final fake = FakeHttpClient((request) async {
        sentBody = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        return jsonStreamedResponse(201, {
          'message': {
            'id': 'server-msg-2',
            'conversationId': 'conv-1',
            'senderUserId': 'me',
            'clientMessageId': sentBody['clientMessageId'],
            'messageType': 'location',
            'latitude': 27.7172,
            'longitude': 85.324,
            'clientCreatedAt': DateTime.now().toIso8601String(),
          },
        });
      });
      ApiClient.instance = ApiClient(httpClient: fake);
      final service = CommunicationService();

      await service.sendLocation('conv-1', latitude: 27.7172, longitude: 85.324);

      expect(sentBody['messageType'], 'location');
      expect(sentBody['latitude'], 27.7172);
      expect(sentBody.containsKey('body'), isFalse);
    });
  });
}
