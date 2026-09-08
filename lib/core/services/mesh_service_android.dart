import 'dart:typed_data';
import 'package:nearby_connections/nearby_connections.dart';

const String _serviceId = 'com.resqnet.mesh';
const Strategy _strategy = Strategy.P2P_CLUSTER;

Function(String, dynamic)? _onConnectionInitiatedCallback;
Function(String, bool)? _onConnectionResultCallback;
Function(String) ? _onDisconnectedCallback;
Function(String, Uint8List)? _onPayloadReceivedCallback;

Future<void> startAdvertising(
  String userName, {
  required Function(String, dynamic) onConnectionInitiated,
  required Function(String, bool) onConnectionResult,
  required Function(String) onDisconnected,
}) async {
  _onConnectionInitiatedCallback = onConnectionInitiated;
  _onConnectionResultCallback = onConnectionResult;
  _onDisconnectedCallback = onDisconnected;

  await Nearby().startAdvertising(
    userName,
    _strategy,
    onConnectionInitiated: (id, info) => onConnectionInitiated(id, info),
    onConnectionResult: (id, status) =>
        onConnectionResult(id, status == Status.CONNECTED),
    onDisconnected: onDisconnected,
    serviceId: _serviceId,
  );
}

Future<void> startDiscovery(
  String userName, {
  required Function(String, String) onEndpointFound,
  required Function(String?) onEndpointLost,
  required Function(String, Uint8List) onPayloadReceived,
}) async {
  _onPayloadReceivedCallback = onPayloadReceived;

  await Nearby().startDiscovery(
    userName,
    _strategy,
    onEndpointFound: (id, name, serviceId) => onEndpointFound(id, name),
    onEndpointLost: onEndpointLost,
    serviceId: _serviceId,
  );
}

Future<void> acceptConnection(
  String endpointId, {
  required Function(String, Uint8List) onPayloadReceived,
}) async {
  await Nearby().acceptConnection(
    endpointId,
    onPayLoadRecieved: (endpointId, payload) {
      if (payload.type == PayloadType.BYTES && payload.bytes != null) {
        onPayloadReceived(endpointId, payload.bytes!);
      }
    },
    onPayloadTransferUpdate: (_, __) {},
  );
}

Future<void> requestConnection(String userName, String endpointId) async {
  await Nearby().requestConnection(
    userName,
    endpointId,
    // Both sides must handle onConnectionInitiated and call acceptConnection
    onConnectionInitiated: (id, info) {
      if (_onConnectionInitiatedCallback != null) {
        _onConnectionInitiatedCallback!(id, info);
      }
    },
    onConnectionResult: (id, status) {
      if (_onConnectionResultCallback != null) {
        _onConnectionResultCallback!(id, status == Status.CONNECTED);
      }
    },
    onDisconnected: (id) {
      if (_onDisconnectedCallback != null) {
        _onDisconnectedCallback!(id);
      }
    },
  );
}

Future<void> sendBytes(String endpointId, Uint8List bytes) async {
  await Nearby().sendBytesPayload(endpointId, bytes);
}

Future<void> stopAll() async {
  await Nearby().stopAllEndpoints();
  await Nearby().stopAdvertising();
  await Nearby().stopDiscovery();
}