/// Every tunable number the earthquake detector uses — all genuinely
/// overridable via the constructor. Deliberately separate from
/// [CrashConfig] — an earthquake and a car crash look nothing alike on
/// an accelerometer (sustained low-frequency oscillation vs. one sharp
/// linear shock), so they never share thresholds.
///
/// Starting values are informed by the Seismic-Network reference
/// implementation (STA/LTA ratio 3.0, 1s/30s windows, 0.1g amplitude
/// gate) rather than invented from nothing — see the analysis for why.
class EarthquakeConfig {
  const EarthquakeConfig({
    this.sampleRateHz = 50,
    this.amplitudeGate = 0.98,
    this.shortWindowSamples = 50,
    this.longWindowSamples = 1500,
    this.triggerRatio = 3.5,
    this.stationaryThreshold = 0.3,
    this.minimumSustainedDuration = const Duration(seconds: 2),
    this.minimumOscillations = 4,
    this.reAlertCooldown = const Duration(minutes: 2),
    this.weightStaLtaRatio = 0.25,
    this.weightDuration = 0.20,
    this.weightOscillation = 0.20,
    this.weightIqr = 0.15,
    this.weightCav = 0.20,
    this.candidateThreshold = 0.5,
    this.confirmationThreshold = 0.7,
    this.confirmationCountdown = const Duration(seconds: 20),
    this.gyroSuppressionThreshold = 0.3,
    this.gyroHardRejectThreshold = 2.0,
    this.minimumCav = 0.5,
  });

  /// Sample rate the detector runs at (matches MotionSensorService's
  /// SensorInterval.gameInterval, ~50Hz).
  final int sampleRateHz;

  /// Layer-1 gate: below this, don't even bother running STA/LTA — cheap
  /// early-out for the overwhelming majority of samples, which are just
  /// background noise. ~0.1g.
  final double amplitudeGate;

  /// STA window: ~1 second.
  final int shortWindowSamples;

  /// LTA window: ~30 seconds — long enough that a single knock or tap
  /// barely moves the baseline, unlike the old 10s window.
  final int longWindowSamples;

  /// STA/LTA ratio that counts as a candidate.
  final double triggerRatio;

  /// Phone must be resting (LTA below this) to even monitor — screens out
  /// active handling, walking, driving.
  final double stationaryThreshold;

  /// A real quake's shaking holds up for multiple seconds; a single tap
  /// or knock is over in a few hundred milliseconds. Require the ratio to
  /// stay above [triggerRatio] for at least this long before treating it
  /// as a genuine candidate.
  final Duration minimumSustainedDuration;

  /// Earthquakes oscillate back and forth; a tap/knock/drop is one
  /// impulse. Minimum number of sign changes (direction reversals) in
  /// the short window's derivative required to call it oscillatory
  /// rather than impulsive.
  final int minimumOscillations;

  /// Don't re-alert more often than this.
  final Duration reAlertCooldown;

  // --- Confidence weights (sum to 1.0) ---
  final double weightStaLtaRatio;
  final double weightDuration;
  final double weightOscillation;

  /// Weight for the IQR (interquartile range) of the short-window
  /// magnitude samples — a real seismic waveform has a distinctive spread
  /// across its full window, unlike a short transient that's mostly flat
  /// except for one brief excursion.
  final double weightIqr;

  /// Weight for CAV (cumulative absolute velocity — the seismology term
  /// for the running integral of |acceleration| over time) accumulated
  /// across the whole sustained-candidate period, not just one window
  /// snapshot. Genuine shaking accumulates this steadily over multiple
  /// seconds; a brief pickup's CAV is front-loaded and small.
  final double weightCav;

  /// Confidence needed to raise a local candidate at all.
  final double candidateThreshold;

  /// Confidence needed to show the user a confirmation prompt.
  final double confirmationThreshold;

  final Duration confirmationCountdown;

  // --- Gyro/orientation rejection (phone-pickup fix) ---
  /// Peak gyroscope magnitude (rad/s) during the candidate window below
  /// which no suppression is applied — ambient ground shaking barely
  /// rotates a resting phone.
  final double gyroSuppressionThreshold;

  /// Peak gyroscope magnitude (rad/s) at or above which the candidate is
  /// hard-rejected regardless of every other score — this is the
  /// magnitude of rotation a deliberate pickup/rotation produces, which
  /// genuine seismic shaking of a resting phone does not.
  final double gyroHardRejectThreshold;

  /// Minimum accumulated CAV over the sustained-candidate period required
  /// to count as genuine sustained shaking — a hard gate alongside
  /// [minimumOscillations], not just a weighted contributor.
  final double minimumCav;
}
