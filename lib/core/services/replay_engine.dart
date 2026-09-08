import 'dart:async';
import 'dart:math';
import '../models/recorded_session.dart';
import '../models/sensor_sample.dart';

/// Replays a [RecordedSession]'s samples as a `Stream<SensorSample>` at a
/// controllable speed — the join point that lets a recorded session run
/// back through the *unmodified* production detectors via the
/// `debugSampleStream` hooks CrashDetectionService/SeismicService already
/// expose for testing:
///
/// ```dart
/// final engine = ReplayEngine(session);
/// final crash = CrashDetectionService(debugSampleStream: engine.stream, ...);
/// crash.start();
/// await engine.play(speedMultiplier: 10);
/// ```
///
/// Deliberately preserves each sample's *relative* timing (scaled by
/// [play]'s speedMultiplier) rather than blasting every sample through
/// instantly: both detectors key their sustained-duration/stillness/STA-
/// LTA windows off real elapsed time (`DateTime.now()`), not the sample's
/// own timestamp, so a zero-delay replay would desync from what the
/// detector is actually measuring and produce a meaningless result. Use a
/// large speedMultiplier for fast-but-still-real-time playback instead.
class ReplayEngine {
  ReplayEngine(this.session);

  final RecordedSession session;
  // sync:true delivers each add() to listeners immediately instead of
  // scheduling it as a microtask — without it, the very last sample of a
  // fast replay can still be in-flight when play()'s Future resolves,
  // making the caller see one fewer sample than was actually replayed.
  // Safe here: nothing downstream calls back into this controller from
  // within its own listener.
  final StreamController<SensorSample> _controller =
      StreamController<SensorSample>.broadcast(sync: true);

  bool _playing = false;
  int _samplesEmitted = 0;

  Stream<SensorSample> get stream => _controller.stream;
  bool get isPlaying => _playing;
  int get samplesEmitted => _samplesEmitted;

  /// Plays every sample in [session] in recorded order. Completes once
  /// the last sample has been emitted (or immediately, for an empty
  /// session — not an error, just nothing to play). [speedMultiplier]
  /// scales the real gap between consecutive recorded timestamps (2.0 =
  /// twice as fast); [minInterSampleDelay] floors how short that gap is
  /// allowed to shrink to, so a very high multiplier doesn't degrade into
  /// a tight synchronous loop. Calling [stop] mid-playback ends it early
  /// without error.
  Future<void> play({
    double speedMultiplier = 1.0,
    Duration minInterSampleDelay = const Duration(microseconds: 500),
  }) async {
    if (_playing) return;
    if (speedMultiplier <= 0) {
      throw ArgumentError.value(
          speedMultiplier, 'speedMultiplier', 'must be > 0');
    }
    _playing = true;
    _samplesEmitted = 0;
    DateTime? previousTimestamp;

    for (final sample in session.samples) {
      if (!_playing) break;
      if (previousTimestamp != null) {
        final originalGap = sample.timestamp.difference(previousTimestamp);
        final scaledMicros = (originalGap.inMicroseconds / speedMultiplier).round();
        final delay = Duration(
            microseconds: max(scaledMicros, minInterSampleDelay.inMicroseconds));
        await Future.delayed(delay);
      }
      previousTimestamp = sample.timestamp;
      if (!_controller.isClosed) {
        _controller.add(sample.toSensorSample());
      }
      _samplesEmitted++;
    }
    _playing = false;
  }

  /// Ends playback early — the in-flight [play] future completes as soon
  /// as its current delay finishes.
  void stop() {
    _playing = false;
  }

  Future<void> dispose() async {
    _playing = false;
    await _controller.close();
  }
}
