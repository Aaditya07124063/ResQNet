import 'dart:typed_data';

Future<void> startAdvertising(
  String userName, {
  required Function(String, dynamic) onConnectionInitiated,
  required Function(String, bool) onConnectionResult,
  required Function(String) onDisconnected,
}) async {}

Future<void> startDiscovery(
  String userName, {
  required Function(String, String) onEndpointFound,
  required Function(String) onEndpointLost,
  required Function(String, Uint8List) onPayloadReceived,
}) async {}

Future<void> acceptConnection(
  String endpointId, {
  required Function(String, Uint8List) onPayloadReceived,
}) async {}

Future<void> requestConnection(String userName, String endpointId) async {}

Future<void> sendBytes(String endpointId, Uint8List bytes) async {}

Future<void> stopAll() async {}