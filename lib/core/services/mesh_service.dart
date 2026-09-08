import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/emergency_message.dart';
import '../models/nearby_device.dart';
import '../utils/origin_signature_verifier.dart';
import 'device_key_service.dart';
import 'emergency_outbox_store.dart';

import 'mesh_service_android.dart'
    if (dart.library.html) 'mesh_service_stub.dart'
    as platform;
import 'mesh_service_ios.dart' as ios_platform;

/// Store-and-forward mesh transport over the project's existing platform
/// transports (Android: `nearby_connections`; iOS: the bespoke
/// MultipeerConnectivity plugin) — this file extends, never replaces,
/// either. Phase 7 hardening added on top of the original
/// discovery/connection logic below:
///
/// - Deduplication is PERSISTENT (EmergencyOutboxStore's processed-id
///   ledger), not just the in-memory `_seenMessageIds` Set — a restart no
///   longer forgets what's already been seen/relayed (Section 13).
/// - Hop limit is enforced from the MESSAGE's OWN `maxHops` (originally
///   signed, when an origin envelope is present), not a hardcoded
///   constant — a relay can no longer silently apply a looser limit than
///   the origin actually authorized.
/// - TTL (`expiresAt`) is enforced — an expired message is dropped, never
///   relayed further (Section 5/7).
/// - Every relay hop gets a fresh `messageId` and appends this device's
///   own id to a bounded `relayPath`, both for basic loop avoidance (a
///   message that already passed through this device is dropped rather
///   than re-broadcast) and diagnostics — neither is signed or trusted as
///   a security control (see origin_envelope.dart's own doc comment).
/// - Outgoing relay traffic goes through a bounded, priority-ordered
///   queue (CRITICAL/HIGH before MEDIUM/LOW) so a burst of ordinary
///   traffic can never starve emergency traffic, and so a flood of
///   distinct messages can't grow memory without bound (Section 15/21).
class MeshService extends ChangeNotifier {
  /// [testOutboxStore]/[testDeviceId] exist ONLY for tests that simulate
  /// multiple independent devices within a single process (see
  /// test/mesh_multi_device_test.dart) — a real device only ever runs one
  /// MeshService against the one real EmergencyOutboxStore.instance and
  /// its own real DeviceKeyService-derived id, which is exactly what
  /// omitting both parameters (the only way production code ever
  /// constructs this class) still does, unchanged.
  MeshService({
    @visibleForTesting EmergencyOutboxStore? testOutboxStore,
    @visibleForTesting String? testDeviceId,
  })  : _outboxStore = testOutboxStore ?? EmergencyOutboxStore.instance,
        _testDeviceId = testDeviceId;

  final EmergencyOutboxStore _outboxStore;
  final String? _testDeviceId;

  final _uuid = const Uuid();

  final List<NearbyDevice> _discoveredDevices = [];
  final List<NearbyDevice> _connectedDevices = [];
  final List<EmergencyMessage> _messages = [];
  final Set<String> _seenMessageIds = {};
  final Set<String> _connectingDevices = {};

  final List<EmergencyMessage> _relayQueue = [];
  static const int _maxRelayQueueSize = 200;

  /// Bounds the locally-displayed message history so a peer sending many
  /// distinct (individually valid) messages cannot grow this device's
  /// memory without limit over a long mesh session (Section 15/21) —
  /// this is a display-history cap only; it never touches
  /// [EmergencyOutboxStore], the durable, unbounded record of this
  /// device's OWN sent SOS events.
  static const int _maxDisplayedMessages = 500;

  void _trimMessagesIfNeeded() {
    if (_messages.length > _maxDisplayedMessages) {
      _messages.removeRange(_maxDisplayedMessages, _messages.length);
    }
  }
  bool _isDrainingRelayQueue = false;
  String? _localDeviceId;

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  String _localDeviceName = 'ResQNet-Device';

  List<NearbyDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);
  List<NearbyDevice> get connectedDevices =>
      List.unmodifiable(_connectedDevices);
  List<EmergencyMessage> get messages => List.unmodifiable(_messages);
  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  int get connectedCount => _connectedDevices.length;
  bool get isIOS => Platform.isIOS;

  bool isConnecting(String deviceId) => _connectingDevices.contains(deviceId);

  void setDeviceName(String name) {
    _localDeviceName = 'ResQNet-$name';
  }

  Future<void> startMeshNetwork() async {
    if (Platform.isAndroid) {
      await _startAndroidMesh();
    } else if (Platform.isIOS) {
      await _startIOSMesh();
    }
  }

  Future<void> _startAndroidMesh() async {
    try {
      await platform.startAdvertising(
        _localDeviceName,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      _isAdvertising = true;

      await platform.startDiscovery(
        _localDeviceName,
        onEndpointFound: (id, name) {
          if (!_discoveredDevices.any((d) => d.deviceId == id)) {
            _discoveredDevices
                .add(NearbyDevice(deviceId: id, deviceName: name));
            notifyListeners();
          }
          if (_localDeviceName.compareTo('ResQNet-$name') < 0) {
            _autoConnect(id);
          }
        },
        onEndpointLost: (id) {
          if (id != null) {
            _discoveredDevices.removeWhere((d) => d.deviceId == id);
            _connectingDevices.remove(id);
            notifyListeners();
          }
        },
        onPayloadReceived: (endpointId, bytes) {
          _handleIncomingPayload(bytes);
        },
      );
      _isDiscovering = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Android mesh error: $e');
    }
  }

  Future<void> _autoConnect(String endpointId) async {
    if (_connectedDevices.any((d) => d.deviceId == endpointId)) return;
    if (_connectingDevices.contains(endpointId)) return;

    _connectingDevices.add(endpointId);
    notifyListeners();

    try {
      await platform.requestConnection(_localDeviceName, endpointId);
    } catch (e) {
      debugPrint('Auto-connect failed: $e');
      _connectingDevices.remove(endpointId);
      notifyListeners();
    }
  }

  Future<void> _startIOSMesh() async {
    try {
      await ios_platform.startAdvertising(
        _localDeviceName,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      _isAdvertising = true;

      await ios_platform.startDiscovery(
        _localDeviceName,
        onEndpointFound: (id, name) {
          if (!_discoveredDevices.any((d) => d.deviceId == id)) {
            _discoveredDevices
                .add(NearbyDevice(deviceId: id, deviceName: name));
            notifyListeners();
          }
          // Tie-break so only one side invites — otherwise both peers can
          // invite each other at once and MultipeerConnectivity glares.
          if (_localDeviceName.compareTo(name) < 0) {
            _autoConnectIOS(id);
          }
        },
        onEndpointLost: (id) {
          if (id != null) {
            _discoveredDevices.removeWhere((d) => d.deviceId == id);
            _connectingDevices.remove(id);
            notifyListeners();
          }
        },
        onPayloadReceived: (endpointId, bytes) {
          _handleIncomingPayload(bytes);
        },
      );
      _isDiscovering = true;
      notifyListeners();
    } catch (e) {
      debugPrint('iOS mesh error: $e');
    }
  }

  Future<void> _autoConnectIOS(String endpointId) async {
    if (_connectedDevices.any((d) => d.deviceId == endpointId)) return;
    if (_connectingDevices.contains(endpointId)) return;

    _connectingDevices.add(endpointId);
    notifyListeners();

    try {
      await ios_platform.requestConnection(_localDeviceName, endpointId);
    } catch (e) {
      debugPrint('iOS auto-connect failed: $e');
      _connectingDevices.remove(endpointId);
      notifyListeners();
    }
  }

  void _onConnectionInitiated(String id, dynamic info) {
    if (Platform.isAndroid) {
      platform.acceptConnection(
        id,
        onPayloadReceived: (endpointId, bytes) {
          _handleIncomingPayload(bytes);
        },
      );
    } else if (Platform.isIOS) {
      ios_platform.acceptConnection(
        id,
        onPayloadReceived: (endpointId, bytes) {
          _handleIncomingPayload(bytes);
        },
      );
    }
  }

  void _onConnectionResult(String id, bool connected) {
    _connectingDevices.remove(id);

    final idx = _discoveredDevices.indexWhere((d) => d.deviceId == id);
    NearbyDevice device;
    if (idx != -1) {
      device = _discoveredDevices[idx];
    } else {
      device = NearbyDevice(deviceId: id, deviceName: id);
      _discoveredDevices.add(device);
    }

    if (connected) {
      device.isConnected = true;
      if (!_connectedDevices.any((d) => d.deviceId == id)) {
        _connectedDevices.add(device);
      }
      debugPrint('✅ Connected to $id');
    } else {
      device.isConnected = false;
      _connectedDevices.removeWhere((d) => d.deviceId == id);
      debugPrint('❌ Connection failed for $id');
    }
    notifyListeners();
  }

  void _onDisconnected(String id) {
    _connectedDevices.removeWhere((d) => d.deviceId == id);
    _connectingDevices.remove(id);
    final idx = _discoveredDevices.indexWhere((d) => d.deviceId == id);
    if (idx != -1) _discoveredDevices[idx].isConnected = false;
    notifyListeners();
  }

  /// The local mesh device identity (Phase 2/3's `deviceId`, NOT the
  /// per-endpoint id `nearby_connections`/MultipeerConnectivity assign —
  /// see device_key_service.dart's own doc comment on why these are kept
  /// separate). Used only for `relayPath` loop avoidance here; cached
  /// after the first lookup since it never changes within a session.
  Future<String?> _ensureLocalDeviceId() async {
    final testId = _testDeviceId;
    if (testId != null) return testId;
    final cached = _localDeviceId;
    if (cached != null) return cached;
    try {
      final material = await DeviceKeyService.instance.ensureKeyPair();
      _localDeviceId = material.deviceId;
      return material.deviceId;
    } on DeviceKeyUnavailableException {
      // Loop avoidance still works via messageId-based dedup even without
      // a device id available — this is a secondary safeguard, not the
      // only one, so its absence must never block relay entirely.
      return null;
    }
  }

  void _handleIncomingPayload(Uint8List bytes) {
    unawaited(_handleIncomingPayloadAsync(bytes));
  }

  /// Test-only entry point for the exact same payload-handling logic the
  /// real platform callback (`onPayloadReceived`) drives — dedup, TTL,
  /// hop-limit, loop-avoidance, and relay-queueing all happen here.
  /// Exists because starting the real mesh network in a plain
  /// `flutter test` run would hit the actual `nearby_connections`/
  /// MultipeerConnectivity platform channels, which aren't available
  /// outside a real device/emulator.
  @visibleForTesting
  Future<void> handleIncomingPayloadForTesting(Uint8List bytes) => _handleIncomingPayloadAsync(bytes);

  /// A legitimate message (text + coordinates + a full 20-second voice
  /// note, base64-encoded — see VoiceNoteService.maxDuration) tops out
  /// around 150 KB. Bounded generously above that so no real SOS is ever
  /// rejected, but a malicious/misbehaving peer cannot force this device
  /// to spend CPU decoding/parsing an arbitrarily large blob (Section
  /// 15/21's flooding-safeguard requirement) — checked BEFORE any
  /// decode/parse work happens, on the raw byte length alone.
  static const int _maxPayloadBytes = 512 * 1024;

  Future<void> _handleIncomingPayloadAsync(Uint8List bytes) async {
    if (bytes.length > _maxPayloadBytes) {
      debugPrint('mesh_event_rejected: payload too large (${bytes.length} bytes)');
      return;
    }

    EmergencyMessage msg;
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      msg = EmergencyMessage.fromJson(json);
    } catch (e) {
      debugPrint('Payload parse error: $e');
      return;
    }

    // TTL: an expired event must not be shown or relayed further,
    // regardless of how it arrived (Section 5/7/14 — no infinite
    // circulation of stale emergencies).
    if (msg.isExpired) {
      debugPrint('mesh_event_expired: ${msg.id}');
      return;
    }

    // Persistent dedup — checked by the EVENT id (msg.id), not the
    // per-hop messageId, since the same emergency arriving via two
    // different relay routes must still be recognized as one event
    // (Section 5's duplicate-detection requirement, Scenario E).
    if (_seenMessageIds.contains(msg.id) || await _outboxStore.hasProcessed(msg.id)) {
      debugPrint('mesh_event_rejected: duplicate ${msg.id}');
      return;
    }
    _seenMessageIds.add(msg.id);
    await _outboxStore.markProcessed(msg.id);

    // Local origin authentication (required receive-path check — a
    // device must never display or relay an event as if its signature
    // were checked when it never was, and a malicious relay must not be
    // able to alter the signed payload without this device detecting
    // it). Only outcomes that are POSITIVE EVIDENCE of tampering/forgery
    // (a key/signature were present and checkable, and the check failed)
    // cause a drop; a missing/unavailable public key leaves the event
    // UNVERIFIED but still shown/relayed — absence of proof is not proof
    // of an attack.
    final localVerification = verifyOriginEnvelopeLocally(envelope: msg.originEnvelope, eventId: msg.id);
    switch (localVerification) {
      case LocalOriginVerificationResult.signatureInvalid:
      case LocalOriginVerificationResult.keyIdMismatch:
      case LocalOriginVerificationResult.expired:
        debugPrint('mesh_event_rejected: local signature check failed (${localVerification.name}) ${msg.id}');
        return;
      case LocalOriginVerificationResult.signatureValidSelfConsistent:
        msg = msg.copyWith(originVerifiedLocally: true);
        break;
      case LocalOriginVerificationResult.noEnvelope:
      case LocalOriginVerificationResult.malformed:
        break;
    }

    _messages.insert(0, msg);
    _trimMessagesIfNeeded();
    notifyListeners();
    debugPrint('mesh_event_received: ${msg.id} hop=${msg.hopCount}/${msg.maxHops}');

    // Hop limit: enforced from the MESSAGE's OWN maxHops (signed, when an
    // origin envelope is present) — not a value this relay could loosen.
    if (msg.hopCount >= msg.maxHops) {
      debugPrint('mesh_event_rejected: hop limit reached ${msg.id}');
      return;
    }

    final localDeviceId = await _ensureLocalDeviceId();
    // Loop avoidance: if this device's own id is already in the relay
    // path, this message has already passed through here — forwarding it
    // again cannot help and risks a cycle.
    if (localDeviceId != null && msg.relayPath.contains(localDeviceId)) {
      debugPrint('mesh_event_rejected: loop detected ${msg.id}');
      return;
    }

    final boundedRelayPath = [
      ...msg.relayPath,
      if (localDeviceId != null) localDeviceId,
    ];
    // relayPath is bounded by construction: it can never exceed maxHops
    // entries, since hopCount (incremented below) is checked against
    // maxHops on every hop before this point is ever reached.
    final relayed = msg.copyWith(
      messageId: _uuid.v4(),
      hopCount: msg.hopCount + 1,
      isRelayed: true,
      relayPath: boundedRelayPath,
    );
    _enqueueForRelay(relayed);
    debugPrint('mesh_event_relayed: ${relayed.id} hop=${relayed.hopCount}');
  }

  Future<void> broadcastMessage(EmergencyMessage message) async {
    if (_seenMessageIds.contains(message.id)) return;
    _seenMessageIds.add(message.id);
    await _outboxStore.markProcessed(message.id);
    final localDeviceId = await _ensureLocalDeviceId();
    final outgoing = message.copyWith(
      messageId: message.messageId ?? _uuid.v4(),
      relayPath: localDeviceId != null ? [localDeviceId] : message.relayPath,
    );
    _messages.insert(0, outgoing);
    _trimMessagesIfNeeded();
    notifyListeners();
    _enqueueForRelay(outgoing);
    // Phase 20: this used to also write a Firestore `sos_history/{uid}`
    // record here — removed. SosService.triggerSos() (called by
    // SosDispatchService just before this) now records the SAME event
    // with the ResQNet backend directly (POST /api/v1/sos), which is what
    // sos_history_screen.dart reads from; writing it a second time here
    // would just be a duplicate, and mesh's own local history
    // ([_messages]/[messages] below) already covers the "what did this
    // device see over the mesh" view this method's own name/history
    // pertains to.
  }

  int _priorityRank(PriorityLevel p) {
    switch (p) {
      case PriorityLevel.critical:
        return 0;
      case PriorityLevel.high:
        return 1;
      case PriorityLevel.medium:
        return 2;
      case PriorityLevel.low:
        return 3;
    }
  }

  /// Adds [message] to the bounded, priority-ordered outgoing relay
  /// queue. SOS (critical/high priority) is always processed ahead of
  /// ordinary traffic (medium/low) — emergency traffic must never be
  /// starved (Section 15). Bounded to [_maxRelayQueueSize]: once full,
  /// only a message with strictly higher priority than the current
  /// lowest-priority queued item can displace it — this is a storage/
  /// flooding safeguard (Section 20/21), not a claim that every message
  /// is guaranteed relay.
  /// Test-only observation point: every message actually offered to the
  /// relay queue, in order — the real transport can't be observed in a
  /// plain `flutter test` run (no connected peers are possible without a
  /// real platform channel), so this is how tests verify "was this
  /// dropped before ever attempting to relay" (e.g. hop-limit/TTL
  /// rejection, which return early in
  /// _handleIncomingPayloadAsync BEFORE this method is ever called) vs
  /// "was it queued for relay". Has no effect on production behavior.
  @visibleForTesting
  final List<EmergencyMessage> relayAttemptsForTesting = [];

  void _enqueueForRelay(EmergencyMessage message) {
    relayAttemptsForTesting.add(message);
    if (_relayQueue.length >= _maxRelayQueueSize) {
      _relayQueue.sort((a, b) => _priorityRank(a.priority).compareTo(_priorityRank(b.priority)));
      final lowestPriorityQueued = _relayQueue.last;
      if (_priorityRank(message.priority) < _priorityRank(lowestPriorityQueued.priority)) {
        _relayQueue.removeLast();
      } else {
        debugPrint('mesh_relay_queue_full: dropping ${message.id}');
        return;
      }
    }
    _relayQueue.add(message);
    _relayQueue.sort((a, b) => _priorityRank(a.priority).compareTo(_priorityRank(b.priority)));
    unawaited(_drainRelayQueue());
  }

  /// Test-only observation point: the actual SEND (drain) order, as
  /// opposed to [relayAttemptsForTesting]'s enqueue order — this is what
  /// proves priority reordering actually happens, since a message
  /// enqueued later but with higher priority can drain BEFORE one
  /// enqueued earlier. Has no effect on production behavior.
  @visibleForTesting
  final List<EmergencyMessage> relayDrainOrderForTesting = [];

  Future<void> _drainRelayQueue() async {
    if (_isDrainingRelayQueue) return;
    _isDrainingRelayQueue = true;
    try {
      while (_relayQueue.isNotEmpty) {
        final next = _relayQueue.removeAt(0);
        relayDrainOrderForTesting.add(next);
        _broadcastBytes(utf8.encode(jsonEncode(next.toJson())));
        // Yields control so a burst of queued sends can't block incoming
        // payload handling or the UI thread.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _isDrainingRelayQueue = false;
    }
  }

  void _broadcastBytes(List<int> bytes) {
    if (Platform.isAndroid) {
      for (final device in _connectedDevices) {
        platform.sendBytes(device.deviceId, Uint8List.fromList(bytes));
      }
    } else if (Platform.isIOS) {
      for (final device in _connectedDevices) {
        ios_platform.sendBytes(device.deviceId, Uint8List.fromList(bytes));
      }
    }
  }

  Future<void> connectToDevice(String endpointId) async {
    if (Platform.isAndroid) {
      await _autoConnect(endpointId);
    } else if (Platform.isIOS) {
      await _autoConnectIOS(endpointId);
    }
  }

  Future<void> stopMeshNetwork() async {
    if (Platform.isAndroid) {
      await platform.stopAll();
    } else if (Platform.isIOS) {
      await ios_platform.stopAll();
    }
    _isAdvertising = false;
    _isDiscovering = false;
    _connectedDevices.clear();
    _connectingDevices.clear();
    notifyListeners();
  }

  void addLocalMessage(EmergencyMessage message) {
    if (_seenMessageIds.contains(message.id)) return;
    _seenMessageIds.add(message.id);
    _messages.insert(0, message);
    _trimMessagesIfNeeded();
    notifyListeners();
  }
}