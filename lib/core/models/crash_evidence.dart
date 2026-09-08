enum CrashState {
  normal,
  possibleImpact,
  verifyingImpact,
  crashConfirmed,
  cancelled,
}

/// The individual per-signal scores (each 0.0–1.0) behind one crash
/// confidence evaluation, kept around as a struct — not just a final
/// number — specifically so [DETECTION] logging and the data-collection
/// export can show *why* a given confidence was reached, not just what it
/// was.
class CrashEvidence {
  final double accelerationScore;
  final double gyroScore;
  final double speedDropScore;
  final double drivingContextScore;
  final double postImpactScore;
  final double totalConfidence;
  final double peakLinearAccel;
  final double peakGyroRate;
  final double? speedDropMps;
  final String drivingContext;

  /// True if a sustained sub-[CrashConfig.freefallThreshold] period was
  /// found in the ~1s before the impact candidate — the physical
  /// signature of an object falling, not a vehicle collision.
  final bool precededByFreefall;

  /// True only when the candidate has REAL independent evidence the phone
  /// was in a moving vehicle: genuine GPS speed (not the vibration-only
  /// heuristic) above [CrashConfig.minimumMovingSpeedForVehicleEvidence]
  /// at candidate time, AND a measured post-impact speed drop of at least
  /// [CrashConfig.minimumRequiredSpeedDrop]. CRASH_CONFIRMED is
  /// unreachable without this being true, regardless of how high the
  /// other scores are.
  final bool hasIndependentVehicleEvidence;

  /// Human-readable classification of what this candidate looks like:
  /// 'PHONE_DROP', 'VEHICLE_EVENT', or 'UNCLASSIFIED'.
  final String classification;

  const CrashEvidence({
    required this.accelerationScore,
    required this.gyroScore,
    required this.speedDropScore,
    required this.drivingContextScore,
    required this.postImpactScore,
    required this.totalConfidence,
    required this.peakLinearAccel,
    required this.peakGyroRate,
    this.speedDropMps,
    required this.drivingContext,
    this.precededByFreefall = false,
    this.hasIndependentVehicleEvidence = false,
    this.classification = 'UNCLASSIFIED',
  });

  static const zero = CrashEvidence(
    accelerationScore: 0,
    gyroScore: 0,
    speedDropScore: 0,
    drivingContextScore: 0,
    postImpactScore: 0,
    totalConfidence: 0,
    peakLinearAccel: 0,
    peakGyroRate: 0,
    drivingContext: 'unknown',
  );

  @override
  String toString() => 'CrashEvidence('
      'accel=${accelerationScore.toStringAsFixed(2)}, '
      'gyro=${gyroScore.toStringAsFixed(2)}, '
      'speedDrop=${speedDropScore.toStringAsFixed(2)}, '
      'context=${drivingContextScore.toStringAsFixed(2)} ($drivingContext), '
      'postImpact=${postImpactScore.toStringAsFixed(2)}, '
      'freefall=$precededByFreefall, '
      'independentEvidence=$hasIndependentVehicleEvidence, '
      'class=$classification, '
      'total=${totalConfidence.toStringAsFixed(2)})';
}
