class NearbyDevice {
  final String deviceId;
  final String deviceName;
  bool isConnected;
  DateTime lastSeen;

  NearbyDevice({
    required this.deviceId,
    required this.deviceName,
    this.isConnected = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();
}
