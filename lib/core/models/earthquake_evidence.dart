enum EarthquakeState {
  normal,
  candidate,
  verifying,
  confirmed,
  cancelled,
}

class EarthquakeEvidence {
  final double ratioScore;
  final double durationScore;
  final double oscillationScore;
  final double totalConfidence;
  final double staLtaRatio;
  final Duration sustainedDuration;
  final int oscillationCount;
  final bool multiDeviceCorroborated;
  final int corroboratingDeviceCount;

  /// IQR (interquartile range) of the short-window magnitude samples —
  /// 0.0-1.0 normalized score.
  final double iqrScore;

  /// CAV (cumulative absolute velocity) accumulated across the whole
  /// sustained-candidate period — 0.0-1.0 normalized score.
  final double cavScore;
  final double cumulativeAbsoluteVelocity;

  /// Peak gyroscope magnitude (rad/s) seen during the candidate window.
  final double peakGyroMagnitude;

  /// Multiplier (0.0-1.0) applied to the weighted feature total based on
  /// [peakGyroMagnitude] — 1.0 when gyro is quiet, ramping to 0.0 as it
  /// approaches [EarthquakeConfig.gyroHardRejectThreshold]. This is what
  /// makes "strong manual orientation/gyro movement suppresses earthquake
  /// confidence" true even when the accelerometer waveform alone looks
  /// oscillatory.
  final double gyroSuppressionFactor;

  /// True when [peakGyroMagnitude] hard-rejected the candidate outright
  /// (see [EarthquakeConfig.gyroHardRejectThreshold]).
  final bool rejectedByGyro;

  const EarthquakeEvidence({
    required this.ratioScore,
    required this.durationScore,
    required this.oscillationScore,
    required this.totalConfidence,
    required this.staLtaRatio,
    required this.sustainedDuration,
    required this.oscillationCount,
    this.multiDeviceCorroborated = false,
    this.corroboratingDeviceCount = 0,
    this.iqrScore = 0,
    this.cavScore = 0,
    this.cumulativeAbsoluteVelocity = 0,
    this.peakGyroMagnitude = 0,
    this.gyroSuppressionFactor = 1.0,
    this.rejectedByGyro = false,
  });

  static const zero = EarthquakeEvidence(
    ratioScore: 0,
    durationScore: 0,
    oscillationScore: 0,
    totalConfidence: 0,
    staLtaRatio: 0,
    sustainedDuration: Duration.zero,
    oscillationCount: 0,
  );

  @override
  String toString() => 'EarthquakeEvidence('
      'ratio=${ratioScore.toStringAsFixed(2)} (STA/LTA=${staLtaRatio.toStringAsFixed(1)}), '
      'duration=${durationScore.toStringAsFixed(2)} (${sustainedDuration.inMilliseconds}ms), '
      'oscillation=${oscillationScore.toStringAsFixed(2)} (count=$oscillationCount), '
      'iqr=${iqrScore.toStringAsFixed(2)}, '
      'cav=${cavScore.toStringAsFixed(2)} (${cumulativeAbsoluteVelocity.toStringAsFixed(1)}), '
      'gyroSuppression=${gyroSuppressionFactor.toStringAsFixed(2)} '
      '(peakGyro=${peakGyroMagnitude.toStringAsFixed(2)}, rejected=$rejectedByGyro), '
      'corroborated=$multiDeviceCorroborated ($corroboratingDeviceCount devices), '
      'total=${totalConfidence.toStringAsFixed(2)})';
}
