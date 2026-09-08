import 'sensor_sample.dart';

/// One timestamped row of a recorded sensor session — everything Phase 3
/// asked to capture, in one place. This is deliberately richer than
/// [SensorSample] (which is only what the live detectors need): it also
/// carries gravity (derived from raw − linear, not a new sensor), GPS,
/// a coarse orientation label, and a snapshot of detector state, because
/// the whole point of recording is to be able to look back and see what
/// every other signal was doing at the moment a sample was captured.
class RecordedSample {
  final DateTime timestamp;

  final double accelX, accelY, accelZ;
  final double linearAccelX, linearAccelY, linearAccelZ;
  final double gravityX, gravityY, gravityZ;
  final double gyroX, gyroY, gyroZ;

  /// Null whenever no recent GPS fix was available — never a placeholder
  /// zero, so a reviewer (or a future classifier) can't mistake "no
  /// signal" for "stationary".
  final double? gpsSpeedMps;
  final double? gpsAccuracy;
  final double? latitude;
  final double? longitude;

  final String orientation;
  final String drivingContextState;
  final String earthquakeDetectorState;
  final String crashDetectorState;
  final double? crashConfidence;
  final double? earthquakeConfidence;

  const RecordedSample({
    required this.timestamp,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.linearAccelX,
    required this.linearAccelY,
    required this.linearAccelZ,
    required this.gravityX,
    required this.gravityY,
    required this.gravityZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    this.gpsSpeedMps,
    this.gpsAccuracy,
    this.latitude,
    this.longitude,
    required this.orientation,
    required this.drivingContextState,
    required this.earthquakeDetectorState,
    required this.crashDetectorState,
    this.crashConfidence,
    this.earthquakeConfidence,
  });

  /// Converts back to the type the live detection pipeline actually
  /// consumes — this is the join point [ReplayEngine] uses to feed a
  /// recorded session back through CrashDetectionService/SeismicService's
  /// existing `debugSampleStream` hooks unmodified.
  SensorSample toSensorSample() => SensorSample(
        timestamp: timestamp,
        accelX: accelX,
        accelY: accelY,
        accelZ: accelZ,
        linearAccelX: linearAccelX,
        linearAccelY: linearAccelY,
        linearAccelZ: linearAccelZ,
        gyroX: gyroX,
        gyroY: gyroY,
        gyroZ: gyroZ,
      );

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'accelX': accelX,
        'accelY': accelY,
        'accelZ': accelZ,
        'linearAccelX': linearAccelX,
        'linearAccelY': linearAccelY,
        'linearAccelZ': linearAccelZ,
        'gravityX': gravityX,
        'gravityY': gravityY,
        'gravityZ': gravityZ,
        'gyroX': gyroX,
        'gyroY': gyroY,
        'gyroZ': gyroZ,
        'gpsSpeedMps': gpsSpeedMps,
        'gpsAccuracy': gpsAccuracy,
        'latitude': latitude,
        'longitude': longitude,
        'orientation': orientation,
        'drivingContextState': drivingContextState,
        'earthquakeDetectorState': earthquakeDetectorState,
        'crashDetectorState': crashDetectorState,
        'crashConfidence': crashConfidence,
        'earthquakeConfidence': earthquakeConfidence,
      };

  /// Throws [FormatException] (via the required-field lookups below) if
  /// [json] is missing/mistyped a required field — surfaced by
  /// [RecordedSession.fromJson] as a [SessionFormatException] with the
  /// sample index, so a corrupted file fails loudly instead of producing
  /// a silently-wrong replay.
  factory RecordedSample.fromJson(Map<String, dynamic> json) {
    double reqDouble(String key) => (json[key] as num).toDouble();
    double? optDouble(String key) => (json[key] as num?)?.toDouble();
    String reqString(String key) => json[key] as String;

    return RecordedSample(
      timestamp: DateTime.parse(json['timestamp'] as String),
      accelX: reqDouble('accelX'),
      accelY: reqDouble('accelY'),
      accelZ: reqDouble('accelZ'),
      linearAccelX: reqDouble('linearAccelX'),
      linearAccelY: reqDouble('linearAccelY'),
      linearAccelZ: reqDouble('linearAccelZ'),
      gravityX: reqDouble('gravityX'),
      gravityY: reqDouble('gravityY'),
      gravityZ: reqDouble('gravityZ'),
      gyroX: reqDouble('gyroX'),
      gyroY: reqDouble('gyroY'),
      gyroZ: reqDouble('gyroZ'),
      gpsSpeedMps: optDouble('gpsSpeedMps'),
      gpsAccuracy: optDouble('gpsAccuracy'),
      latitude: optDouble('latitude'),
      longitude: optDouble('longitude'),
      orientation: reqString('orientation'),
      drivingContextState: reqString('drivingContextState'),
      earthquakeDetectorState: reqString('earthquakeDetectorState'),
      crashDetectorState: reqString('crashDetectorState'),
      crashConfidence: optDouble('crashConfidence'),
      earthquakeConfidence: optDouble('earthquakeConfidence'),
    );
  }

  static const csvHeader = 'timestamp,accelX,accelY,accelZ,'
      'linearAccelX,linearAccelY,linearAccelZ,'
      'gravityX,gravityY,gravityZ,gyroX,gyroY,gyroZ,'
      'gpsSpeedMps,gpsAccuracy,latitude,longitude,'
      'orientation,drivingContextState,earthquakeDetectorState,'
      'crashDetectorState,crashConfidence,earthquakeConfidence';

  String toCsvRow() => [
        timestamp.toIso8601String(),
        accelX,
        accelY,
        accelZ,
        linearAccelX,
        linearAccelY,
        linearAccelZ,
        gravityX,
        gravityY,
        gravityZ,
        gyroX,
        gyroY,
        gyroZ,
        gpsSpeedMps ?? '',
        gpsAccuracy ?? '',
        latitude ?? '',
        longitude ?? '',
        orientation,
        drivingContextState,
        earthquakeDetectorState,
        crashDetectorState,
        crashConfidence ?? '',
        earthquakeConfidence ?? '',
      ].join(',');
}
