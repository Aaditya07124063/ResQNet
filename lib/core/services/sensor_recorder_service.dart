import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/recorded_sample.dart';
import '../models/recorded_session.dart';
import '../models/sensor_sample.dart';
import 'crash_detection_service.dart';
import 'driving_context_service.dart';
import 'location_service.dart';
import 'motion_sensor_service.dart';
import 'seismic_service.dart';

/// Raw sensor data recorder for the developer/data-collection workflow —
/// the "Sensor streams → MotionSensorService → SensorRecorder →
/// RecordedSession → CSV/JSON storage" half of the Phase 3 pipeline.
///
/// Deliberately independent from the production detection logic: it only
/// *reads* CrashDetectionService/SeismicService's public state/evidence
/// getters for context, never calls into them, and never changes what
/// they do. It shares the same accelerometer/gyroscope subscription as
/// both detectors via [MotionSensorService]'s reference-counted
/// acquire/release — starting a recording never opens a second
/// accelerometer listener alongside an active detector.
///
/// Bounded/battery-conscious by design: only the OS sensors' existing
/// shared stream is read (no new listener overhead), the effective
/// recording rate is downsampled from the ~50Hz shared stream (see
/// [recordEveryNth]), and a session hard-stops itself at [maxSamples]
/// rather than growing without bound.
class SensorRecorderService extends ChangeNotifier {
  SensorRecorderService({
    LocationService? locationService,
    CrashDetectionService? crashDetection,
    SeismicService? seismicDetection,
    DrivingContextService? drivingContext,
    this.recordEveryNth = 2,
    this.maxSamples = 15000, // ~10 minutes at the default ~25Hz effective rate
    @visibleForTesting this.debugSampleStream,
  })  : _locationService = locationService,
        _crashDetection = crashDetection,
        _seismicDetection = seismicDetection,
        _drivingContext = drivingContext;

  final LocationService? _locationService;
  final CrashDetectionService? _crashDetection;
  final SeismicService? _seismicDetection;
  final DrivingContextService? _drivingContext;

  /// Record every Nth sample from the shared ~50Hz stream (2 = ~25Hz).
  final int recordEveryNth;

  /// Hard cap on samples per session — recording auto-stops and the
  /// session is saved once this is reached, rather than growing forever.
  final int maxSamples;

  /// Test-only: bypass MotionSensorService/real GPS with a synthetic
  /// stream — same pattern as CrashDetectionService/SeismicService's own
  /// debugSampleStream hook.
  @visibleForTesting
  final Stream<SensorSample>? debugSampleStream;

  StreamSubscription<SensorSample>? _sub;
  bool _isRecording = false;
  bool _startedLocationTracking = false;
  int _sampleCounter = 0;

  String? _sessionId;
  DateTime? _startTime;
  List<String> _labels = const [];
  final List<RecordedSample> _buffer = [];
  RecordedSession? _lastCompletedSession;

  bool get isRecording => _isRecording;
  int get bufferedSampleCount => _buffer.length;
  String? get currentSessionId => _sessionId;

  Future<void> startRecording({List<String> labels = const []}) async {
    if (_isRecording) return;
    _isRecording = true;
    _sessionId = const Uuid().v4();
    _startTime = DateTime.now();
    _labels = labels;
    _buffer.clear();
    _sampleCounter = 0;
    _lastCompletedSession = null;

    if (debugSampleStream != null) {
      _sub = debugSampleStream!.listen(_onSample);
    } else {
      MotionSensorService.instance.acquire();
      _sub = MotionSensorService.instance.samples.listen(_onSample);
      final locationService = _locationService;
      if (locationService != null && !locationService.isTracking) {
        locationService.startTracking();
        _startedLocationTracking = true;
      }
    }
    notifyListeners();
  }

  /// Stops recording, persists the session to disk, and returns it. Safe
  /// to call when not recording — returns the most recently completed
  /// session (e.g. one that already auto-stopped at [maxSamples]) if
  /// there is one, otherwise null.
  Future<RecordedSession?> stopRecording() async {
    if (!_isRecording) return _lastCompletedSession;
    return _finishRecording();
  }

  Future<RecordedSession> _finishRecording() async {
    _isRecording = false;
    _sub?.cancel();
    _sub = null;
    if (debugSampleStream == null) {
      MotionSensorService.instance.release();
      if (_startedLocationTracking) {
        _locationService?.stopTracking();
        _startedLocationTracking = false;
      }
    }

    final session = RecordedSession(
      sessionId: _sessionId!,
      startTime: _startTime!,
      endTime: DateTime.now(),
      devicePlatform: _devicePlatformName(),
      samplingRateHz: (50 / recordEveryNth).round(),
      labels: _labels,
      samples: List.unmodifiable(_buffer),
    );
    _lastCompletedSession = session;
    notifyListeners();
    await saveSession(session);
    return session;
  }

  void _onSample(SensorSample sample) {
    _sampleCounter++;
    if (_sampleCounter % recordEveryNth != 0) return;

    final gravityX = sample.accelX - sample.linearAccelX;
    final gravityY = sample.accelY - sample.linearAccelY;
    final gravityZ = sample.accelZ - sample.linearAccelZ;

    final position = _locationService?.currentPosition;
    // GPS accuracy floor mirrors DrivingContextService's own noise
    // filter — a wildly inaccurate fix is worse than no fix at all.
    final hasUsableFix =
        position != null && (position.speedAccuracy <= 0 || position.speedAccuracy <= 5);

    _buffer.add(RecordedSample(
      timestamp: sample.timestamp,
      accelX: sample.accelX,
      accelY: sample.accelY,
      accelZ: sample.accelZ,
      linearAccelX: sample.linearAccelX,
      linearAccelY: sample.linearAccelY,
      linearAccelZ: sample.linearAccelZ,
      gravityX: gravityX,
      gravityY: gravityY,
      gravityZ: gravityZ,
      gyroX: sample.gyroX,
      gyroY: sample.gyroY,
      gyroZ: sample.gyroZ,
      gpsSpeedMps: hasUsableFix ? position.speed : null,
      gpsAccuracy: hasUsableFix ? position.speedAccuracy : null,
      latitude: hasUsableFix ? position.latitude : null,
      longitude: hasUsableFix ? position.longitude : null,
      orientation: _classifyOrientation(gravityX, gravityY, gravityZ),
      drivingContextState: _drivingContext?.context.name ?? 'unknown',
      earthquakeDetectorState: _seismicDetection?.state.name ?? 'inactive',
      crashDetectorState: _crashDetection?.state.name ?? 'inactive',
      crashConfidence: _crashDetection?.evidence.totalConfidence,
      earthquakeConfidence: _seismicDetection?.evidence.totalConfidence,
    ));
    notifyListeners();

    if (_buffer.length >= maxSamples) {
      _finishRecording();
    }
  }

  /// Coarse device-orientation label from the gravity vector — whichever
  /// axis gravity dominates tells you which way the phone is currently
  /// held. Not a detection feature, just a human-readable log field.
  String _classifyOrientation(double gx, double gy, double gz) {
    final ax = gx.abs(), ay = gy.abs(), az = gz.abs();
    const restThreshold = 3.0; // below this, orientation isn't well-defined
    if (max(ax, max(ay, az)) < restThreshold) return 'unknown';
    if (az >= ax && az >= ay) return gz > 0 ? 'face_up' : 'face_down';
    if (ay >= ax && ay >= az) {
      return gy > 0 ? 'portrait_upright' : 'portrait_upside_down';
    }
    return gx > 0 ? 'landscape_right' : 'landscape_left';
  }

  String _devicePlatformName() {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  // --- Storage ---

  Future<Directory> _sessionsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/resqnet_sensor_sessions');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> saveSession(RecordedSession session) async {
    final dir = await _sessionsDir();
    final file = File('${dir.path}/${session.sessionId}.json');
    await file.writeAsString(session.toJsonString());
    return file.path;
  }

  Future<List<String>> listSavedSessionIds() async {
    final dir = await _sessionsDir();
    if (!await dir.exists()) return const [];
    final ids = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final name = entity.uri.pathSegments.last;
        ids.add(name.substring(0, name.length - '.json'.length));
      }
    }
    ids.sort();
    return ids;
  }

  Future<RecordedSession> loadSession(String sessionId) async {
    final dir = await _sessionsDir();
    final file = File('${dir.path}/$sessionId.json');
    if (!await file.exists()) {
      throw SessionFormatException('no session found with id $sessionId');
    }
    final contents = await file.readAsString();
    return RecordedSession.fromJsonString(contents);
  }

  Future<String> exportSessionAsCsv(String sessionId) async {
    final session = await loadSession(sessionId);
    final dir = await _sessionsDir();
    final file = File('${dir.path}/$sessionId.csv');
    await file.writeAsString(session.toCsv());
    return file.path;
  }

  Future<String> exportSessionAsJson(String sessionId) async {
    final dir = await _sessionsDir();
    return '${dir.path}/$sessionId.json';
  }

  /// The app's cache directory, scoped to a subfolder just for files
  /// handed to the OS share sheet — separate from [_sessionsDir]'s
  /// private, non-shareable app-storage location. On Android, share_plus
  /// ships its own FileProvider (declared in its bundled manifest, no
  /// setup needed here) that's configured to serve content:// URIs for
  /// files under the app's cache dir, which is exactly what
  /// [getTemporaryDirectory] returns.
  Future<Directory> _shareCacheDir() async {
    final dir = await getTemporaryDirectory();
    final shareDir = Directory('${dir.path}/resqnet_shared_sessions');
    if (!await shareDir.exists()) await shareDir.create(recursive: true);
    return shareDir;
  }

  Future<File> _writeShareableFile(String filename, String contents) async {
    final dir = await _shareCacheDir();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(contents);
    return file;
  }

  /// Hands the session's CSV to the platform share sheet (Android's
  /// ACTION_SEND, iOS's UIActivityViewController) as a `resqnet_
  /// <sessionId>.csv` file — never the private app-storage path. Uses the
  /// exact same [RecordedSession.toCsv] generation [exportSessionAsCsv]
  /// does; this only changes where the copy handed to the OS lives.
  Future<ShareResult> shareSessionCsv(String sessionId) async {
    final session = await loadSession(sessionId);
    final file =
        await _writeShareableFile('resqnet_$sessionId.csv', session.toCsv());
    return SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'text/csv')],
      subject: 'ResQNet sensor session $sessionId (CSV)',
    ));
  }

  /// Same as [shareSessionCsv] but for the session's JSON.
  Future<ShareResult> shareSessionJson(String sessionId) async {
    final session = await loadSession(sessionId);
    final file = await _writeShareableFile(
        'resqnet_$sessionId.json', session.toJsonString());
    return SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/json')],
      subject: 'ResQNet sensor session $sessionId (JSON)',
    ));
  }

  Future<void> deleteSession(String sessionId) async {
    final dir = await _sessionsDir();
    for (final ext in ['.json', '.csv']) {
      final file = File('${dir.path}/$sessionId$ext');
      if (await file.exists()) await file.delete();
    }
  }

  @override
  void dispose() {
    if (_isRecording) {
      _sub?.cancel();
      if (debugSampleStream == null) {
        MotionSensorService.instance.release();
        if (_startedLocationTracking) _locationService?.stopTracking();
      }
    }
    super.dispose();
  }
}
