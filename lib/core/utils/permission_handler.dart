import 'package:permission_handler/permission_handler.dart';

Future<void> requestAllPermissions() async {
  await Permission.bluetooth.request();
  await Permission.bluetoothScan.request();
  await Permission.bluetoothAdvertise.request();
  await Permission.bluetoothConnect.request();
  await Permission.locationWhenInUse.request();
  await Permission.nearbyWifiDevices.request();
}