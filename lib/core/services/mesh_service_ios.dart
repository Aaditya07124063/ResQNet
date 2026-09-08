import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Dart-side bridge to the native iOS mesh transport implemented with
/// Apple's MultipeerConnectivity framework (see
/// ios/Runner/MeshConnectivityPlugin.swift). Mirrors the function surface of
/// mesh_service_android.dart so mesh_service.dart can drive either platform
/// the same way.
const MethodChannel _channel = MethodChannel('com.resqnet.mesh/methods');
const EventChannel _events = EventChannel('com.resqnet.mesh/events');

Function(String, dynamic)? _onConnectionInitiatedCallback;
Function(String, bool)? _onConnectionResultCallback;
Function(String)? _onDisconnectedCallback;
Function(String, Uint8List)? _onPayloadReceivedCallback;
Function(String, String)? _onEndpointFoundCallback;
Function(String?)? _onEndpointLostCallback;

StreamSubscription? _eventSub;

void _ensureEventListener() {
  _eventSub ??= _events.receiveBroadcastStream().listen((event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['event'] as String?) {
      case 'endpointFound':
        _onEndpointFoundCallback?.call(
            map['id'] as String, map['name'] as String);
        break;
      case 'endpointLost':
        _onEndpointLostCallback?.call(map['id'] as String?);
        break;
      case 'connectionInitiated':
        _onConnectionInitiatedCallback?.call(map['id'] as String, map['info']);
        break;
      case 'connectionResult':
        _onConnectionResultCallback?.call(
            map['id'] as String, map['connected'] as bool);
        break;
      case 'disconnected':
        _onDisconnectedCallback?.call(map['id'] as String);
        break;
      case 'payloadReceived':
        final bytes = map['bytes'] as Uint8List;
        _onPayloadReceivedCallback?.call(map['id'] as String, bytes);
        break;
    }
  });
}

Future<void> startAdvertising(
  String userName, {
  required Function(String, dynamic) onConnectionInitiated,
  required Function(String, bool) onConnectionResult,
  required Function(String) onDisconnected,
}) async {
  _onConnectionInitiatedCallback = onConnectionInitiated;
  _onConnectionResultCallback = onConnectionResult;
  _onDisconnectedCallback = onDisconnected;
  _ensureEventListener();
  await _channel.invokeMethod('startAdvertising', {'userName': userName});
}

Future<void> startDiscovery(
  String userName, {
  required Function(String, String) onEndpointFound,
  required Function(String?) onEndpointLost,
  required Function(String, Uint8List) onPayloadReceived,
}) async {
  _onEndpointFoundCallback = onEndpointFound;
  _onEndpointLostCallback = onEndpointLost;
  _onPayloadReceivedCallback = onPayloadReceived;
  _ensureEventListener();
  await _channel.invokeMethod('startDiscovery', {'userName': userName});
}

Future<void> acceptConnection(
  String endpointId, {
  required Function(String, Uint8List) onPayloadReceived,
}) async {
  _onPayloadReceivedCallback = onPayloadReceived;
  await _channel.invokeMethod('acceptConnection', {'endpointId': endpointId});
}

Future<void> requestConnection(String userName, String endpointId) async {
  await _channel.invokeMethod(
      'requestConnection', {'userName': userName, 'endpointId': endpointId});
}

Future<void> sendBytes(String endpointId, Uint8List bytes) async {
  await _channel
      .invokeMethod('sendBytes', {'endpointId': endpointId, 'bytes': bytes});
}

Future<void> stopAll() async {
  await _channel.invokeMethod('stopAll');
}
