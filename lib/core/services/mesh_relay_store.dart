import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emergency_message.dart';

/// Whether a relayed event has been handed to the ResQNet backend by this
/// device acting as an Internet gateway.
enum GatewayUploadState {
  /// Signed SOS waiting for this device to be online and signed in.
  pending,

  /// The backend accepted it (or already had it from another gateway).
  uploaded,

  /// The backend definitively refused it (invalid signature, revoked key,
  /// expired) — never retried.
  rejected,

  /// Not something a gateway can upload: unsigned (origin cannot be
  /// verified), a cancellation notice, or not an SOS.
  notUploadable,
}

/// One emergency this device received from another device and is carrying
/// onward (store-and-forward).
class RelayRecord {
  const RelayRecord({
    required this.message,
    required this.storedAt,
    this.receivedFrom,
    this.forwardedTo = const [],
    required this.gatewayState,
    this.gatewayAttempts = 0,
    this.lastGatewayAttemptAt,
  });

  /// The copy to forward (hop count already incremented by this device).
  final EmergencyMessage message;
  final DateTime storedAt;

  /// Mesh endpoint it arrived from — never sent back there.
  final String? receivedFrom;

  /// Mesh endpoints this device has already handed it to.
  final List<String> forwardedTo;
  final GatewayUploadState gatewayState;
  final int gatewayAttempts;
  final DateTime? lastGatewayAttemptAt;

  String get eventId => message.id;

  RelayRecord copyWith({
    List<String>? forwardedTo,
    GatewayUploadState? gatewayState,
    int? gatewayAttempts,
    DateTime? lastGatewayAttemptAt,
  }) =>
      RelayRecord(
        message: message,
        storedAt: storedAt,
        receivedFrom: receivedFrom,
        forwardedTo: forwardedTo ?? this.forwardedTo,
        gatewayState: gatewayState ?? this.gatewayState,
        gatewayAttempts: gatewayAttempts ?? this.gatewayAttempts,
        lastGatewayAttemptAt: lastGatewayAttemptAt ?? this.lastGatewayAttemptAt,
      );

  Map<String, dynamic> toJson() => {
        'message': message.toJson(),
        'storedAt': storedAt.toIso8601String(),
        'receivedFrom': receivedFrom,
        'forwardedTo': forwardedTo,
        'gatewayState': gatewayState.name,
        'gatewayAttempts': gatewayAttempts,
        'lastGatewayAttemptAt': lastGatewayAttemptAt?.toIso8601String(),
      };

  factory RelayRecord.fromJson(Map<String, dynamic> json) => RelayRecord(
        message: EmergencyMessage.fromJson(json['message'] as Map<String, dynamic>),
        storedAt: DateTime.parse(json['storedAt'] as String),
        receivedFrom: json['receivedFrom'] as String?,
        forwardedTo: (json['forwardedTo'] as List?)?.cast<String>() ?? const [],
        gatewayState: GatewayUploadState.values.firstWhere(
          (s) => s.name == json['gatewayState'],
          orElse: () => GatewayUploadState.notUploadable,
        ),
        gatewayAttempts: json['gatewayAttempts'] as int? ?? 0,
        lastGatewayAttemptAt:
            json['lastGatewayAttemptAt'] != null ? DateTime.parse(json['lastGatewayAttemptAt'] as String) : null,
      );
}

/// True when a gateway may upload [message] to `POST /api/v1/sos`: it must
/// be a signed SOS (the backend verifies the origin signature and never
/// attributes it to the uploader) and not a cancellation notice, which the
/// backend would otherwise record as a new SOS.
bool isGatewayUploadable(EmergencyMessage message) {
  final envelope = message.originEnvelope;
  if (envelope == null || message.isCancellation) return false;
  if (envelope.eventType != 'sos') return false;
  if ((envelope.message ?? '').startsWith('resqnet-cancel:')) return false;
  return true;
}

/// Durable store-and-forward buffer for emergencies received from other
/// devices. Without it a relay only reaches peers connected at the moment
/// it received the event; with it, B keeps A's SOS and hands it to C when
/// C comes into range later — possibly after a restart.
///
/// Bounded ([maxRecords], lowest priority / oldest evicted first) and
/// time-limited (expired events are dropped; unsigned events with no
/// expiry are kept at most [unsignedRetention]). Voice-note audio is not
/// stored: it is not covered by the origin signature and would make the
/// buffer large.
class MeshRelayStore {
  MeshRelayStore({@visibleForTesting String keyPrefix = ''}) : _key = '${keyPrefix}resqnet_mesh_relay_v1';

  static final MeshRelayStore instance = MeshRelayStore();

  static const int maxRecords = 100;
  static const Duration unsignedRetention = Duration(hours: 24);

  final String _key;
  Future<void> _chain = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<RelayRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return <RelayRecord>[];
    try {
      return (jsonDecode(raw) as List).map((e) => RelayRecord.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return <RelayRecord>[];
    }
  }

  Future<void> _save(List<RelayRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(records.map((r) => r.toJson()).toList()));
  }

  bool _isLive(RelayRecord r, DateTime now) {
    if (r.message.isExpired) return false;
    if (r.message.expiresAt == null && now.difference(r.storedAt) > unsignedRetention) return false;
    return true;
  }

  /// Live records still worth carrying, highest priority first.
  Future<List<RelayRecord>> live() async {
    final now = DateTime.now();
    final records = (await loadAll()).where((r) => _isLive(r, now)).toList()
      ..sort((a, b) => a.message.priority.index.compareTo(b.message.priority.index));
    return records;
  }

  /// Stores [relayed] (the copy this device forwards). A second copy of an
  /// event already stored is ignored.
  Future<void> add(EmergencyMessage relayed, {String? receivedFrom}) => _serialized(() async {
        final now = DateTime.now();
        final records = (await loadAll()).where((r) => _isLive(r, now)).toList();
        if (records.any((r) => r.eventId == relayed.id)) return;
        records.add(RelayRecord(
          message: relayed.copyWith(audioBase64: '', audioDurationSeconds: 0),
          storedAt: now,
          receivedFrom: receivedFrom,
          gatewayState:
              isGatewayUploadable(relayed) ? GatewayUploadState.pending : GatewayUploadState.notUploadable,
        ));
        if (records.length > maxRecords) {
          // Evict lowest priority first, then oldest — never an SOS while a
          // lower-priority record remains.
          records.sort((a, b) {
            final byPriority = b.message.priority.index.compareTo(a.message.priority.index);
            return byPriority != 0 ? byPriority : a.storedAt.compareTo(b.storedAt);
          });
          records.removeRange(0, records.length - maxRecords);
        }
        await _save(records);
      });

  Future<RelayRecord?> update(String eventId, RelayRecord Function(RelayRecord current) change) =>
      _serialized(() async {
        final records = await loadAll();
        final index = records.indexWhere((r) => r.eventId == eventId);
        if (index == -1) return null;
        records[index] = change(records[index]);
        await _save(records);
        return records[index];
      });

  Future<void> markForwarded(String eventId, String peerId) => update(
        eventId,
        (r) => r.forwardedTo.contains(peerId) ? r : r.copyWith(forwardedTo: [...r.forwardedTo, peerId]),
      );
}
