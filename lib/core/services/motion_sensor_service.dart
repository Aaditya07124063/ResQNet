import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/sensor_sample.dart';

/// The one and only accelerometer + gyroscope subscription in the app.
///
/// Both CrashDetectionService and SeismicService listen to the broadcast
/// stream this exposes instead of each opening their own sensors_plus
/// listeners — that used to mean two independent, differently-filtered
/// sensor pipelines running in parallel. Reference-counted: the actual OS
/// sensor streams only run while at least one detector has called
/// [acquire], and are properly cancelled once the last one calls
/// [release] — no leaked subscriptions, no listeners left running after
/// every detector has stopped.
///
/// Also does the one gravity-removal pass both detectors need (a simple
/// running low-pass filter — the same technique Android's own "linear
/// acceleration" virtual sensor uses internally) so crash and earthquake
/// detection agree on what "gravity" currently is instead of each
/// filtering independently and drifting apart.
class MotionSensorService {
  MotionSensorService._();
  static final MotionSensorService instance = MotionSensorService._();

  static const double _gravityFilterAlpha = 0.8;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final StreamController<SensorSample> _controller =
      StreamController<SensorSample>.broadcast();

  int _refCount = 0;
  double _gravityX = 0, _gravityY = 0, _gravityZ = 9.8;
  double _lastGyroX = 0, _lastGyroY = 0, _lastGyroZ = 0;

  Stream<SensorSample> get samples => _controller.stream;

  /// Starts the underlying sensors on the first caller; subsequent callers
  /// just increment the reference count and share the same stream.
  void acquire() {
    _refCount++;
    if (_refCount > 1) return;

    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval, // ~20ms, 50Hz
    ).listen(_onAccel);

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((event) {
      _lastGyroX = event.x;
      _lastGyroY = event.y;
      _lastGyroZ = event.z;
    });
  }

  /// Releases one reference; only actually stops the sensors once every
  /// caller that acquired has also released.
  void release() {
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount > 0) return;

    _accelSub?.cancel();
    _accelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
  }

  void _onAccel(AccelerometerEvent event) {
    // Running low-pass estimate of gravity; subtracting it from the raw
    // reading leaves just the device's own motion.
    _gravityX = _gravityFilterAlpha * _gravityX + (1 - _gravityFilterAlpha) * event.x;
    _gravityY = _gravityFilterAlpha * _gravityY + (1 - _gravityFilterAlpha) * event.y;
    _gravityZ = _gravityFilterAlpha * _gravityZ + (1 - _gravityFilterAlpha) * event.z;

    _controller.add(SensorSample(
      timestamp: DateTime.now(),
      accelX: event.x,
      accelY: event.y,
      accelZ: event.z,
      linearAccelX: event.x - _gravityX,
      linearAccelY: event.y - _gravityY,
      linearAccelZ: event.z - _gravityZ,
      gyroX: _lastGyroX,
      gyroY: _lastGyroY,
      gyroZ: _lastGyroZ,
    ));
  }
}
