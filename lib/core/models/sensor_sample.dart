import 'dart:math';

/// One synchronized reading from the accelerometer + gyroscope, taken at
/// the same instant. The crash and earthquake detectors both consume a
/// stream of these — sharing one sensor subscription instead of each
/// opening its own — so there's exactly one accelerometer/gyroscope
/// listener active at a time, not two competing ones.
class SensorSample {
  final DateTime timestamp;

  /// Raw accelerometer reading (includes gravity), m/s^2.
  final double accelX;
  final double accelY;
  final double accelZ;

  /// Gravity-removed acceleration (device motion only), m/s^2 — computed
  /// once by MotionSensorService's running low-pass filter and shared by
  /// both detectors, so they always agree on what "gravity" currently is
  /// instead of each running its own filter and drifting apart.
  final double linearAccelX;
  final double linearAccelY;
  final double linearAccelZ;

  /// Gyroscope reading (rotation rate), rad/s.
  final double gyroX;
  final double gyroY;
  final double gyroZ;

  SensorSample({
    required this.timestamp,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.linearAccelX,
    required this.linearAccelY,
    required this.linearAccelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
  });

  double get accelMagnitude =>
      sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);

  double get linearAccelMagnitude => sqrt(
      linearAccelX * linearAccelX +
          linearAccelY * linearAccelY +
          linearAccelZ * linearAccelZ);

  double get gyroMagnitude => sqrt(gyroX * gyroX + gyroY * gyroY + gyroZ * gyroZ);

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'accelX': accelX,
        'accelY': accelY,
        'accelZ': accelZ,
        'linearAccelX': linearAccelX,
        'linearAccelY': linearAccelY,
        'linearAccelZ': linearAccelZ,
        'gyroX': gyroX,
        'gyroY': gyroY,
        'gyroZ': gyroZ,
      };
}
