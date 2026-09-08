import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

Future<void> requestAllPermissions() async {
  if (Platform.isAndroid) {
    await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
      Permission.notification,
    ].request();
  } else if (Platform.isIOS) {
    await [
      Permission.bluetooth,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();
  }
}