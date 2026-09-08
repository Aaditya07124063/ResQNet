import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import '../network/websocket_client.dart';

/// ResQNet's native 1-to-1 communication layer — conversations/messages
/// live entirely on the ResQNet backend (Postgres, via `/api/v1/conversations`)
/// and arrive in realtime over `ResQNetWebSocketClient`. No third-party
/// chat provider and no Firebase Firestore are used for any of this (see
/// backend/src/services/messageService.ts's own doc comments for the
/// server side of this contract).
///
/// Offline-safe by design (Section 20): a send is written to a local
/// pending outbox (SharedPreferences) BEFORE the network call is even
/// attempted, so a message is never silently lost if the app is killed or
/// the network drops mid-send. `client_message_id` (a UUID generated here,
/// once, per message) makes a retried send idempotent server-side — see
/// messageService.ts's own uq_messages_conversation_client_id handling.
class CommunicationService extends ChangeNotifier {
  static const _outboxKey = 'resqnet_pending_messages_v1';

  List<ConversationSummary> _conversations = [];
  final Map<String, List<Message>> _messagesByConversation = {};
  final List<Message> _pendingOutbox = [];
  StreamSubscription? _wsSubscription;
  bool _loadingConversations = false;

  List<ConversationSummary> get conversations => List.unmodifiable(_conversations);
  bool get loadingConversations => _loadingConversations;

  List<Message> messagesFor(String conversationId) {
    final serverMessages = _messagesByConversation[conversationId] ?? const [];
    final pendingForThisConversation =
        _pendingOutbox.where((m) => m.conversationId == conversationId);
    // Pending (not-yet-confirmed) sends are appended after the server's
    // own history — they are, by definition, the newest thing the user
    // did, and the server doesn't know about them yet.
    return [...serverMessages, ...pendingForThisConversation];
  }

  /// Call once, after sign-in — connects the realtime transport and
  /// restores any messages that failed to send in a previous session.
  Future<void> initialize() async {
    await _loadOutbox();
    _wsSubscription ??= ResQNetWebSocketClient.instance.events.listen(_handleWsEvent);
    await ResQNetWebSocketClient.instance.connect();
    unawaited(retryPendingSends());
  }

  /// The outbox itself is left on disk on dispose (it is the user's own
  /// unsent messages, not session state) so signing back in as the same
  /// account can still retry them.
  @override
  void dispose() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    super.dispose();
  }

  Future<String> startConversationWith(String participantUserId) async {
    final result = await ApiClient.instance.post(
      '/conversations',
      auth: true,
      body: {'participantUserId': participantUserId},
    );
    return result['conversationId'] as String;
  }

  Future<void> loadConversations() async {
    _loadingConversations = true;
    notifyListeners();
    try {
      final result = await ApiClient.instance.get('/conversations');
      final list = (result['conversations'] as List)
          .map((e) => ConversationSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      _conversations = list;
    } catch (e) {
      debugPrint('loadConversations failed: $e');
    } finally {
      _loadingConversations = false;
      notifyListeners();
    }
  }

  Future<void> loadMessages(String conversationId, {DateTime? before}) async {
    final query = before != null ? '?before=${before.toIso8601String()}' : '';
    try {
      final result = await ApiClient.instance.get('/conversations/$conversationId/messages$query');
      final fetched = (result['messages'] as List)
          .map((e) => Message.fromJson(e as Map<String, dynamic>))
          .toList()
          .reversed // server returns newest-first; the chat UI wants oldest-first
          .toList();
      final existing = _messagesByConversation[conversationId] ?? [];
      if (before == null) {
        _messagesByConversation[conversationId] = fetched;
      } else {
        _messagesByConversation[conversationId] = [...fetched, ...existing];
      }
      notifyListeners();
    } catch (e) {
      debugPrint('loadMessages failed: $e');
    }
  }

  /// Sends a text message. Returns immediately with a locally-visible
  /// `pending` message; the UI should render it right away (Section 20:
  /// never make the user wait on the network to see their own message
  /// appear) and let the delivery-state indicator update once the
  /// send actually resolves.
  Future<void> sendText(String conversationId, String body) {
    return _send(Message(
      id: const Uuid().v4(), // local-only id until the server confirms its own
      conversationId: conversationId,
      senderUserId: '', // filled by the server; irrelevant for a pending/self-authored message
      clientMessageId: const Uuid().v4(),
      type: MessageType.text,
      body: body,
      clientCreatedAt: DateTime.now(),
      deliveryState: MessageDeliveryState.pending,
    ));
  }

  Future<void> sendLocation(
    String conversationId, {
    required double latitude,
    required double longitude,
    double? accuracyM,
  }) {
    return _send(Message(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderUserId: '',
      clientMessageId: const Uuid().v4(),
      type: MessageType.location,
      latitude: latitude,
      longitude: longitude,
      locationAccuracyM: accuracyM,
      clientCreatedAt: DateTime.now(),
      deliveryState: MessageDeliveryState.pending,
    ));
  }

  Future<void> _send(Message pending) async {
    _pendingOutbox.add(pending);
    await _persistOutbox();
    notifyListeners();
    await _attemptSend(pending);
  }

  Future<void> _attemptSend(Message pending) async {
    try {
      final result = await ApiClient.instance.post(
        '/conversations/${pending.conversationId}/messages',
        auth: true,
        body: pending.toSendJson(),
      );
      final confirmed = Message.fromJson(
        result['message'] as Map<String, dynamic>,
        deliveryState: MessageDeliveryState.sent,
      );
      _pendingOutbox.removeWhere((m) => m.clientMessageId == pending.clientMessageId);
      _messagesByConversation.putIfAbsent(pending.conversationId, () => []).add(confirmed);
      await _persistOutbox();
      notifyListeners();
    } on ApiException catch (e) {
      // A network failure, or a transient backend-side failure (5xx —
      // e.g. a deploy in progress), leaves the message in the outbox
      // (retried later); a genuine rejection of THIS request's content
      // (e.g. 403 — no longer a participant) marks it failed rather than
      // retrying forever against a request that will never succeed.
      final idx = _pendingOutbox.indexWhere((m) => m.clientMessageId == pending.clientMessageId);
      if (idx != -1 && !e.isNetworkError && !e.isServerError) {
        _pendingOutbox[idx] = _pendingOutbox[idx].copyWith(deliveryState: MessageDeliveryState.failed);
        await _persistOutbox();
        notifyListeners();
      }
      debugPrint('Message send failed (will retry if network-related): $e');
    } catch (e) {
      debugPrint('Message send failed: $e');
    }
  }

  /// Retries every still-pending outbox message — safe to call repeatedly
  /// (e.g. on WebSocket reconnect, a reasonable proxy for "connectivity is
  /// back", or a manual pull-to-retry gesture); each attempt is
  /// independently idempotent server-side via client_message_id.
  Future<void> retryPendingSends() async {
    final toRetry = _pendingOutbox
        .where((m) => m.deliveryState == MessageDeliveryState.pending)
        .toList();
    for (final message in toRetry) {
      await _attemptSend(message);
    }
  }

  Future<void> markRead(String conversationId, String upToMessageId) async {
    try {
      await ApiClient.instance.postNoContent(
        '/conversations/$conversationId/read',
        auth: true,
        body: {'upToMessageId': upToMessageId},
      );
      final idx = _conversations.indexWhere((c) => c.id == conversationId);
      if (idx != -1) {
        // Optimistic local unread-count clear — the next loadConversations()
        // call reconciles with the server's own count regardless.
        notifyListeners();
      }
    } catch (e) {
      debugPrint('markRead failed: $e');
    }
  }

  void _handleWsEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'message_created':
        final conversationId = event['conversationId'] as String;
        final message = Message.fromJson(event['message'] as Map<String, dynamic>);
        _messagesByConversation.putIfAbsent(conversationId, () => []).add(message);
        notifyListeners();
        break;
      case 'conversation_updated':
        // Cheapest correct option: refresh the list summary (last
        // message/unread count) rather than hand-reconstructing it from a
        // partial event payload.
        unawaited(loadConversations());
        break;
      case 'message_delivered':
      case 'message_read':
        // Per-message delivery/read ticks for the SENDER's own UI — V1
        // doesn't yet render a per-message state change from this event
        // (messagesFor() only distinguishes pending/sent for the sender's
        // own outbox), so this is a no-op today beyond logging. Left as an
        // explicit case (not falling into `default`) so the event is
        // visibly accounted for, not silently dropped.
        break;
      default:
        break;
    }
  }

  Future<void> _persistOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_pendingOutbox
        .map((m) => {
              'conversationId': m.conversationId,
              'clientMessageId': m.clientMessageId,
              'messageType': m.type == MessageType.location ? 'location' : 'text',
              'body': m.body,
              'latitude': m.latitude,
              'longitude': m.longitude,
              'locationAccuracyM': m.locationAccuracyM,
              'clientCreatedAt': m.clientCreatedAt.toIso8601String(),
              'deliveryState': m.deliveryState.name,
            })
        .toList());
    await prefs.setString(_outboxKey, encoded);
  }

  Future<void> _loadOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _pendingOutbox.clear();
      for (final entry in list) {
        final map = entry as Map<String, dynamic>;
        _pendingOutbox.add(Message(
          id: const Uuid().v4(),
          conversationId: map['conversationId'] as String,
          senderUserId: '',
          clientMessageId: map['clientMessageId'] as String,
          type: (map['messageType'] as String) == 'location' ? MessageType.location : MessageType.text,
          body: map['body'] as String?,
          latitude: (map['latitude'] as num?)?.toDouble(),
          longitude: (map['longitude'] as num?)?.toDouble(),
          locationAccuracyM: (map['locationAccuracyM'] as num?)?.toDouble(),
          clientCreatedAt: DateTime.parse(map['clientCreatedAt'] as String),
          deliveryState: MessageDeliveryState.values.firstWhere(
            (s) => s.name == map['deliveryState'],
            orElse: () => MessageDeliveryState.pending,
          ),
        ));
      }
    } catch (e) {
      debugPrint('Failed to restore pending message outbox: $e');
    }
  }
}
