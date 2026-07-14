import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/emergency_message.dart';
import '../models/nearby_device.dart';

import 'mesh_service_android.dart'
    if (dart.library.html) 'mesh_service_stub.dart'
    as platform;

class MeshService extends ChangeNotifier {
  final _uuid = const Uuid();

  final List<NearbyDevice> _discoveredDevices = [];
  final List<NearbyDevice> _connectedDevices = [];
  final List<EmergencyMessage> _messages = [];
  final Set<String> _seenMessageIds = {};
  final Set<String> _connectingDevices = {};

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
    _isAdvertising = true;
    _isDiscovering = true;
    notifyListeners();
  }

  void _onConnectionInitiated(String id, dynamic info) {
    platform.acceptConnection(
      id,
      onPayloadReceived: (endpointId, bytes) {
        _handleIncomingPayload(bytes);
      },
    );
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

  void _handleIncomingPayload(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final msg = EmergencyMessage.fromJson(json);
      if (_seenMessageIds.contains(msg.id)) return;
      _seenMessageIds.add(msg.id);
      _messages.insert(0, msg);
      notifyListeners();

      if (msg.hopCount < 10) {
        final relayed =
            msg.copyWith(hopCount: msg.hopCount + 1, isRelayed: true);
        _broadcastBytes(utf8.encode(jsonEncode(relayed.toJson())));
      }
    } catch (e) {
      debugPrint('Payload parse error: $e');
    }
  }

  Future<void> broadcastMessage(EmergencyMessage message) async {
    if (_seenMessageIds.contains(message.id)) return;
    _seenMessageIds.add(message.id);
    _messages.insert(0, message);
    notifyListeners();
    final bytes = utf8.encode(jsonEncode(message.toJson()));
    _broadcastBytes(bytes);
    _saveToHistory(message);
  }

  void _saveToHistory(EmergencyMessage message) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    FirebaseFirestore.instance
        .collection('sos_history')
        .doc(uid)
        .collection('messages')
        .doc(message.id)
        .set(message.toJson())
        .catchError((e) => debugPrint('History save error: $e'));
  }

  void _broadcastBytes(List<int> bytes) {
    if (Platform.isAndroid) {
      for (final device in _connectedDevices) {
        platform.sendBytes(device.deviceId, Uint8List.fromList(bytes));
      }
    }
  }

  Future<void> connectToDevice(String endpointId) async {
    if (Platform.isAndroid) {
      await _autoConnect(endpointId);
    }
  }

  Future<void> stopMeshNetwork() async {
    if (Platform.isAndroid) {
      await platform.stopAll();
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
    notifyListeners();
  }
}