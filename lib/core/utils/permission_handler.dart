import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A group of runtime permissions ResQNet asks for together, with the
/// reason shown to the user before the system prompt.
class ResQNetPermissionGroup {
  const ResQNetPermissionGroup({
    required this.id,
    required this.title,
    required this.reason,
    required this.permissions,
    required this.requiredForSos,
  });

  final String id;
  final String title;
  final String reason;
  final List<Permission> permissions;

  /// Whether SOS loses a delivery path without it (still never blocks SOS).
  final bool requiredForSos;
}

/// Only what the core emergency features use. Microphone, camera, and
/// photos are requested by their own features at the moment they are
/// used, never up front.
List<ResQNetPermissionGroup> resqnetPermissionGroups({bool? isAndroid}) {
  final android = isAndroid ?? Platform.isAndroid;
  return [
    ResQNetPermissionGroup(
      id: 'nearby',
      title: 'Nearby devices',
      reason: 'Sends your SOS to other ResQNet phones nearby over Bluetooth and Wi-Fi, even with no internet '
          'or mobile signal.',
      permissions: android
          ? [
              Permission.bluetoothScan,
              Permission.bluetoothAdvertise,
              Permission.bluetoothConnect,
              Permission.nearbyWifiDevices,
            ]
          : [Permission.bluetooth],
      requiredForSos: true,
    ),
    const ResQNetPermissionGroup(
      id: 'location',
      title: 'Location',
      reason: 'Adds where you are to your SOS so rescuers can find you. Only shared when you send an alert.',
      permissions: [Permission.locationWhenInUse],
      requiredForSos: true,
    ),
    const ResQNetPermissionGroup(
      id: 'notifications',
      title: 'Notifications',
      reason: 'Alerts you when someone nearby sends an SOS, and lets you cancel an automatic crash or '
          'earthquake SOS.',
      permissions: [Permission.notification],
      requiredForSos: false,
    ),
  ];
}

enum GroupPermissionState { granted, denied, permanentlyDenied }

/// Collapses several platform statuses into one state for display: any
/// permanently denied permission needs the settings app to fix.
GroupPermissionState combinePermissionStatuses(Iterable<PermissionStatus> statuses) {
  if (statuses.any((s) => s.isPermanentlyDenied || s.isRestricted)) return GroupPermissionState.permanentlyDenied;
  if (statuses.every((s) => s.isGranted || s.isLimited)) return GroupPermissionState.granted;
  return GroupPermissionState.denied;
}

Future<GroupPermissionState> groupState(ResQNetPermissionGroup group) async {
  final statuses = <PermissionStatus>[];
  for (final permission in group.permissions) {
    statuses.add(await permission.status);
  }
  return combinePermissionStatuses(statuses);
}

Future<GroupPermissionState> requestGroup(ResQNetPermissionGroup group) async {
  final results = await group.permissions.request();
  return combinePermissionStatuses(results.values);
}

const _explainedKey = 'resqnet_permissions_explained_v1';

Future<bool> permissionsExplained() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_explainedKey) ?? false;
}

Future<void> markPermissionsExplained() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_explainedKey, true);
}

/// Requests every group (used after the explanation has been shown).
Future<void> requestAllPermissions() async {
  for (final group in resqnetPermissionGroups()) {
    await requestGroup(group);
  }
}
