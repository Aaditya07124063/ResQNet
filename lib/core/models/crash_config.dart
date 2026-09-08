/// Every tunable number the crash detector uses, in one place, with the
/// reasoning for each starting value — and all of them genuinely
/// overridable via the constructor, not just centralized. Starting
/// values are informed by the researched open-source detectors
/// (BeSafeBox's post-impact stillness window, Tracelet's "jolt only
/// counts while moving" gate), meant to be refined once real ResQNet
/// usage data exists (see DetectionLoggingService). Nothing here is
/// hardcoded inside the detector logic itself.
class CrashConfig {
  const CrashConfig({
    this.impactCandidateThreshold = 25.0,
    this.impactHardFloor = 18.0,
    this.noVehicleContextScoreCap = 0.35,
    this.gyroSignificantRate = 3.0,
    this.speedDropStrong = 8.0,
    this.speedDropWindow = const Duration(seconds: 4),
    this.postImpactStillnessThreshold = 3.0,
    this.postImpactStillnessRequired = const Duration(milliseconds: 600),
    this.postImpactWindow = const Duration(seconds: 6),
    this.weightAcceleration = 0.30,
    this.weightGyro = 0.15,
    this.weightSpeedDrop = 0.25,
    this.weightDrivingContext = 0.10,
    this.weightPostImpactStillness = 0.20,
    this.possibleImpactThreshold = 0.35,
    this.confirmationThreshold = 0.60,
    this.confirmationCountdown = const Duration(seconds: 20),
    this.freefallThreshold = 3.0,
    this.minimumFreefallDuration = const Duration(milliseconds: 100),
    this.freefallLookbackWindow = const Duration(milliseconds: 1000),
    this.minimumMovingSpeedForVehicleEvidence = 3.0,
    this.minimumRequiredSpeedDrop = 2.0,
    this.noIndependentEvidenceScoreCap = 0.40,
  });

  // --- Impact candidate gate ---
  /// Linear-acceleration magnitude (gravity already removed) that marks a
  /// spike as worth evaluating at all, m/s^2. ~2.5g — well below what a
  /// real crash produces, but high enough that normal handling (walking,
  /// setting the phone down) rarely reaches it; this is a candidate gate,
  /// not the crash decision itself.
  final double impactCandidateThreshold;

  /// A spike below this can't be a crash regardless of anything else —
  /// even a perfect driving-context + gyro + stillness match. Keeps a
  /// firm desk-tap from ever reaching the confidence math no matter how
  /// the other signals happen to line up.
  final double impactHardFloor;

  // --- Driving-context requirement ---
  /// Without at least "recently in a vehicle" context, acceleration score
  /// is capped at this — a hard slam on a desk still can't cross the
  /// confirmation threshold, because driving context alone withholds most
  /// of the possible confidence.
  final double noVehicleContextScoreCap;

  // --- Gyroscope corroboration ---
  /// Rotation-rate magnitude (rad/s) that counts as "significant" — real
  /// crashes tumble/jolt the device; a phone that stays rotationally
  /// still through a big linear spike is more consistent with a hard
  /// linear shock (e.g. a dropped phone bouncing) than a vehicle impact.
  final double gyroSignificantRate;

  // --- GPS speed-drop corroboration ---
  /// A crash decelerates the vehicle abruptly. Speed drop (m/s) within
  /// the post-impact window that counts as strong corroboration.
  final double speedDropStrong;
  final Duration speedDropWindow;

  // --- Post-impact stillness ---
  /// Linear-acceleration magnitude below which the device counts as
  /// "still" after a candidate impact.
  final double postImpactStillnessThreshold;
  final Duration postImpactStillnessRequired;
  final Duration postImpactWindow;

  // --- Confidence weights (sum to 1.0) ---
  final double weightAcceleration;
  final double weightGyro;
  final double weightSpeedDrop;
  final double weightDrivingContext;
  final double weightPostImpactStillness;

  // --- State-machine thresholds ---
  /// Confidence needed to leave NORMAL and start actively verifying.
  final double possibleImpactThreshold;

  /// Confidence needed to show the user the confirmation countdown.
  final double confirmationThreshold;

  /// How long the user has to cancel before SOS fires automatically.
  final Duration confirmationCountdown;

  // --- Free-fall / phone-drop rejection ---
  /// Raw (gravity-included) acceleration magnitude below this counts as
  /// "weightless" — a phone at rest reads ~9.8 here; true free-fall reads
  /// near 0. m/s^2.
  final double freefallThreshold;

  /// How long the signal must stay below [freefallThreshold] to count as a
  /// genuine free-fall period rather than one noisy low sample. A drop
  /// from pocket/hand height is airborne for ~150-450ms.
  final Duration minimumFreefallDuration;

  /// How far back before an impact candidate to search for a preceding
  /// free-fall period.
  final Duration freefallLookbackWindow;

  // --- Independent vehicle-motion evidence (required for confirmation) ---
  /// GPS speed (m/s) that counts as "genuinely moving", not just parked
  /// with the engine/road vibration heuristic satisfied. ~11 km/h.
  final double minimumMovingSpeedForVehicleEvidence;

  /// Minimum measured GPS speed drop (m/s) after a candidate impact that
  /// counts as real deceleration evidence — not just the placeholder 0
  /// that results when no GPS speed was ever available.
  final double minimumRequiredSpeedDrop;

  /// Hard cap on total confidence whenever a candidate lacks independent
  /// vehicle-motion evidence (real GPS speed pre-impact + a real measured
  /// drop post-impact) — set below [confirmationThreshold] so accel/gyro/
  /// context/stillness alone, however strong, can never reach
  /// CRASH_CONFIRMED without it. This is what stops a phone drop (or any
  /// vibration+context coincidence) from confirming on its own.
  final double noIndependentEvidenceScoreCap;
}
