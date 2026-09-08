import 'dart:convert';
import 'recorded_sample.dart';

/// Thrown when a session file/map is missing a required field or has a
/// field of the wrong type — a corrupted or hand-edited file fails loudly
/// here instead of producing a silently-wrong replay or export.
class SessionFormatException implements Exception {
  final String message;
  const SessionFormatException(this.message);
  @override
  String toString() => 'SessionFormatException: $message';
}

/// One recorded data-collection session: metadata (Section H of the
/// original spec — session ID, start/end time, device/platform, sampling
/// rate, labels) plus the ordered list of samples themselves.
class RecordedSession {
  final String sessionId;
  final DateTime startTime;
  final DateTime? endTime;
  final String devicePlatform;

  /// Effective recording rate after downsampling (see
  /// SensorRecorderService's `recordEveryNth`) — not the raw sensor rate.
  final int samplingRateHz;
  final List<String> labels;
  final List<RecordedSample> samples;

  const RecordedSession({
    required this.sessionId,
    required this.startTime,
    this.endTime,
    required this.devicePlatform,
    required this.samplingRateHz,
    this.labels = const [],
    this.samples = const [],
  });

  RecordedSession copyWith({
    DateTime? endTime,
    List<String>? labels,
    List<RecordedSample>? samples,
  }) =>
      RecordedSession(
        sessionId: sessionId,
        startTime: startTime,
        endTime: endTime ?? this.endTime,
        devicePlatform: devicePlatform,
        samplingRateHz: samplingRateHz,
        labels: labels ?? this.labels,
        samples: samples ?? this.samples,
      );

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'devicePlatform': devicePlatform,
        'samplingRateHz': samplingRateHz,
        'labels': labels,
        'sampleCount': samples.length,
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  String toJsonString() => jsonEncode(toJson());

  /// Parses a session from a decoded JSON map. Every required field is
  /// looked up explicitly (no silent defaults for structural fields) so a
  /// missing/renamed field surfaces as a clear [SessionFormatException]
  /// rather than a null-cast crash somewhere downstream.
  factory RecordedSession.fromJson(Map<String, dynamic> json) {
    try {
      final sessionId = json['sessionId'] as String;
      final startTime = DateTime.parse(json['startTime'] as String);
      final endTimeRaw = json['endTime'] as String?;
      final devicePlatform = json['devicePlatform'] as String;
      final samplingRateHz = json['samplingRateHz'] as int;
      final labels = (json['labels'] as List?)?.cast<String>() ?? const [];
      final rawSamples = json['samples'] as List?;
      if (rawSamples == null) {
        throw const SessionFormatException(
            'session is missing the "samples" field');
      }

      final samples = <RecordedSample>[];
      for (var i = 0; i < rawSamples.length; i++) {
        try {
          samples.add(
              RecordedSample.fromJson(rawSamples[i] as Map<String, dynamic>));
        } catch (e) {
          throw SessionFormatException('sample at index $i is invalid: $e');
        }
      }

      return RecordedSession(
        sessionId: sessionId,
        startTime: startTime,
        endTime: endTimeRaw != null ? DateTime.parse(endTimeRaw) : null,
        devicePlatform: devicePlatform,
        samplingRateHz: samplingRateHz,
        labels: labels,
        samples: samples,
      );
    } on SessionFormatException {
      rethrow;
    } catch (e) {
      throw SessionFormatException('malformed session data: $e');
    }
  }

  /// Throws [SessionFormatException] on malformed/non-JSON input — the
  /// same exception a caller catches whether the corruption is at the
  /// JSON-syntax level or the schema level.
  factory RecordedSession.fromJsonString(String source) {
    late final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } catch (e) {
      throw SessionFormatException('not valid JSON: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SessionFormatException(
          'top-level JSON value must be an object');
    }
    return RecordedSession.fromJson(decoded);
  }

  String toCsv() {
    final rows = samples.map((s) => s.toCsvRow());
    return ([RecordedSample.csvHeader, ...rows]).join('\n');
  }
}
