import 'package:permission_handler/permission_handler.dart';

Future<void> requestAllPermissions() async {
  try {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
    ].request().timeout(
      const Duration(seconds: 10),
      onTimeout: () => {},
    );
  } catch (e) {
    // Continue even if permissions fail
  }
}