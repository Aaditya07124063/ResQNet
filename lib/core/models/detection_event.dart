/// One row for the developer data-collection mode — everything about a
/// single detector evaluation at one point in time, in a shape that can be
/// exported and later used to validate (or train) a real classifier.
/// This is the only place raw sensor history is written to disk; the
/// detectors themselves never persist samples during normal operation.
class DetectionEvent {
  final DateTime timestamp;
  final String detector; // 'crash' or 'earthquake'
  final double accelX, accelY, accelZ;
  final double gyroX, gyroY, gyroZ;
  final double linearAccelMagnitude;
  final double? gpsSpeedMps;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final String orientation; // e.g. 'portrait', 'unknown'
  final String activityState; // e.g. 'VEHICLE', 'STATIONARY', 'WALKING'
  final String detectorState; // e.g. 'NORMAL', 'POSSIBLE_IMPACT'
  final double confidence;
  final String? eventLabel; // filled in by a human reviewing the export

  /// Detector-assigned classification, e.g. crash's 'PHONE_DROP' /
  /// 'VEHICLE_EVENT' or earthquake's rejection reason. Null when the
  /// detector doesn't produce one.
  final String? classification;

  DetectionEvent({
    required this.timestamp,
    required this.detector,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    required this.linearAccelMagnitude,
    this.gpsSpeedMps,
    this.gpsLatitude,
    this.gpsLongitude,
    required this.orientation,
    required this.activityState,
    required this.detectorState,
    required this.confidence,
    this.eventLabel,
    this.classification,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'detector': detector,
        'accelX': accelX,
        'accelY': accelY,
        'accelZ': accelZ,
        'gyroX': gyroX,
        'gyroY': gyroY,
        'gyroZ': gyroZ,
        'linearAccelMagnitude': linearAccelMagnitude,
        'gpsSpeedMps': gpsSpeedMps,
        'gpsLatitude': gpsLatitude,
        'gpsLongitude': gpsLongitude,
        'orientation': orientation,
        'activityState': activityState,
        'detectorState': detectorState,
        'confidence': confidence,
        'eventLabel': eventLabel,
        'classification': classification,
      };
}
