import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'api_config.dart';
import 'token_storage.dart';

/// Thin client for the ResQNet backend's authenticated WebSocket
/// (backend/src/websocket/wsServer.ts, mounted at `WS_PATH`, default
/// `/ws`) — realtime delivery transport only. The durable source of truth
/// for anything this receives (messages, SOS events) is always the
/// backend/Postgres; this stream exists so an already-open app doesn't
/// have to poll for what a plain HTTPS request would eventually show
/// anyway (Section 3/15 of the communication-phase spec).
///
/// Sends the ResQNet access token as an `Authorization: Bearer` header on
/// the upgrade request (wsAuth.ts's preferred method — `IOWebSocketChannel`
/// supports custom headers on IO platforms, which Android/iOS both are).
/// Auto-reconnects with a capped exponential backoff on any disconnect
/// (server restart, network drop, token rotation) — a dropped socket must
/// never be treated as "no more realtime events, ever" for the rest of
/// the app's lifetime.
class ResQNetWebSocketClient {
  ResQNetWebSocketClient._();
  static final ResQNetWebSocketClient instance = ResQNetWebSocketClient._();

  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _shouldRun = false;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// Decoded `{type, ...}` event payloads — message_created,
  /// message_delivered, message_read, conversation_updated, sos_created,
  /// sos_status_updated, nearby_sos_created (see backend doc comments for
  /// each). Malformed/non-JSON frames are dropped, never surfaced here.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  bool get isConnected => _channel != null;

  /// Idempotent — safe to call again (e.g. after sign-in) even if already
  /// connected/connecting; a no-op in that case.
  Future<void> connect() async {
    if (_shouldRun) return;
    _shouldRun = true;
    await _attemptConnect();
  }

  Future<void> _attemptConnect() async {
    if (!_shouldRun) return;
    final token = await TokenStorage.instance.readAccessToken();
    if (token == null) {
      // Not signed in (yet) — nothing to connect with. disconnect() (on
      // sign-out) or a later connect() call (on sign-in) drives retries,
      // not a timer loop against a token that isn't coming.
      _shouldRun = false;
      return;
    }

    try {
      final uri = _wsUri();
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      await channel.ready;
      _channel = channel;
      _reconnectAttempt = 0;
      _subscription = channel.stream.listen(
        _handleFrame,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('ResQNet WebSocket connect failed: $e');
      _scheduleReconnect();
    }
  }

  Uri _wsUri() {
    final httpBase = Uri.parse(ApiConfig.baseUrl);
    final scheme = httpBase.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: httpBase.host,
      port: httpBase.hasPort ? httpBase.port : null,
      path: '/ws',
    );
  }

  void _handleFrame(dynamic data) {
    try {
      final decoded = jsonDecode(data as String) as Map<String, dynamic>;
      _eventController.add(decoded);
    } catch (e) {
      debugPrint('ResQNet WebSocket: dropped a non-JSON/malformed frame: $e');
    }
  }

  void _handleDisconnect() {
    _channel = null;
    _subscription?.cancel();
    _subscription = null;
    if (_shouldRun) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // Capped exponential backoff: 2s, 4s, 8s, ... up to 60s — reconnects
    // promptly after a brief blip without hammering the server during a
    // real outage.
    final delaySeconds = (2 << _reconnectAttempt.clamp(0, 5)).clamp(2, 60);
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), _attemptConnect);
  }

  /// Call on sign-out — stops reconnect attempts and closes the socket.
  /// Reconnecting later (sign-in again) requires a fresh connect() call.
  void disconnect() {
    _shouldRun = false;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
  }
}
