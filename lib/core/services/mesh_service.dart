import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import '../models/emergency_message.dart';
import '../models/nearby_device.dart';

class MeshService extends ChangeNotifier {
  final Nearby _nearby = Nearby();
  final List<NearbyDevice> _devices = [];
  final List<EmergencyMessage> _messages = [];
  final Set<String> _seenMessageIds = {};
  bool _isRunning = false;

  List<NearbyDevice> get devices => List.unmodifiable(_devices);
  List<EmergencyMessage> get messages => List.unmodifiable(_messages);
  bool get isRunning => _isRunning;
  int get connectedCount => _devices.where((d) => d.isConnected).length;

  void _onPayload(String endId, Payload payload) {
    if (payload.type == PayloadType.BYTES && payload.bytes != null) {
      try {
        final json = jsonDecode(utf8.decode(payload.bytes!));
        final msg = EmergencyMessage.fromJson(json);
        _handleIncoming(msg);
      } catch (_) {}
    }
  }

  void _onConnectionResult(String id, Status status) {
    final idx = _devices.indexWhere((d) => d.deviceId == id);
    if (idx != -1) {
      _devices[idx].isConnected = status == Status.CONNECTED;
      notifyListeners();
    }
  }

  void _onDisconnected(String id) {
    final idx = _devices.indexWhere((d) => d.deviceId == id);
    if (idx != -1) {
      _devices[idx].isConnected = false;
      notifyListeners();
    }
  }

  Future<void> start(String userName) async {
    try {
      await _nearby.startAdvertising(
        userName,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: (id, info) async {
          await _nearby.acceptConnection(id, onPayLoadRecieved: _onPayload);
        },
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      await _nearby.startDiscovery(
        userName,
        Strategy.P2P_CLUSTER,
        onEndpointFound: (id, name, serviceId) {
          if (!_devices.any((d) => d.deviceId == id)) {
            _devices.add(NearbyDevice(deviceId: id, deviceName: name));
            notifyListeners();
          }
        },
        onEndpointLost: (id) {
          if (id != null) {
            _devices.removeWhere((d) => d.deviceId == id);
            notifyListeners();
          }
        },
      );
      _isRunning = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Mesh start error: $e');
    }
  }

  void _handleIncoming(EmergencyMessage msg) {
    if (_seenMessageIds.contains(msg.id)) return;
    _seenMessageIds.add(msg.id);
    _messages.insert(0, msg);
    notifyListeners();
    if (msg.hopCount < 5) {
      _relay(msg.copyWith(isRelayed: true, hopCount: msg.hopCount + 1));
    }
  }

  Future<void> broadcast(EmergencyMessage msg) async {
    if (_seenMessageIds.contains(msg.id)) return;
    _seenMessageIds.add(msg.id);
    _messages.insert(0, msg);
    notifyListeners();
    _relay(msg);
  }

  void _relay(EmergencyMessage msg) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(msg.toJson())));
    for (final d in _devices.where((d) => d.isConnected)) {
      _nearby.sendBytesPayload(d.deviceId, bytes);
    }
  }

  Future<void> connectTo(String deviceId) async {
    try {
      await _nearby.requestConnection(
        'ResQNet',
        deviceId,
        onConnectionInitiated: (id, info) async {
          await _nearby.acceptConnection(id, onPayLoadRecieved: _onPayload);
        },
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      debugPrint('Connection error: $e');
    }
  }

  void addLocalMessage(EmergencyMessage msg) {
    _messages.insert(0, msg);
    notifyListeners();
  }

  Future<void> stop() async {
    await _nearby.stopAllEndpoints();
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    _isRunning = false;
    notifyListeners();
  }
}