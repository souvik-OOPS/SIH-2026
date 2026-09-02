/// Prototype wellness-risk heuristic configuration.
///
/// This is the single review surface for Day 6. None of these values are
/// medically validated thresholds. They are deliberately visible and passed
/// into `RiskEngine` so a review can change policy without changing logic.
class RiskEngineConfig {
  const RiskEngineConfig({
    this.sensorTrust = const SensorTrustConfig(),
    this.baseline = const PersonalBaselineConfig(),
    this.fall = const FallWorkflowConfig(),
    this.fusion = const RiskFusionConfig(),
    this.stateMachine = const RiskStateMachineConfig(),
  });

  final SensorTrustConfig sensorTrust;
  final PersonalBaselineConfig baseline;
  final FallWorkflowConfig fall;
  final RiskFusionConfig fusion;
  final RiskStateMachineConfig stateMachine;
}

/// MAX30102, contact, MPU6050, packet-health inputs for trusting HR and SpO2.
class SensorTrustConfig {
  const SensorTrustConfig({
    this.reliableQuality = 0.70,
    this.reacquireQuality = 0.40,
    this.highMotionAccelerationDeltaG = 0.35,
    this.highMotionGyroscopeDps = 120,
    this.maxHeartRateChangePerSecond = 45,
    this.maxSpo2ChangePerSecond = 5,
    this.packetGap = const Duration(seconds: 6),
    this.missingVitalPenalty = 20,
    this.highMotionPenalty = 40,
    this.impossibleChangePenalty = 40,
    this.minimumTrustForPhysiology = 40,
  });

  /// MAX30102 quality at or above this is reported as reliable.
  final double reliableQuality;

  /// Below this, optical vitals are withheld while the sensor reacquires.
  final double reacquireQuality;

  /// MPU6050 acceleration farther than this from 1 g is high hand motion.
  final double highMotionAccelerationDeltaG;

  /// MPU6050 gyroscope magnitude at or above this is high hand motion.
  final double highMotionGyroscopeDps;
  final double maxHeartRateChangePerSecond;
  final double maxSpo2ChangePerSecond;
  final Duration packetGap;

  /// Confidence-score deductions, in 0-100 points.
  final int missingVitalPenalty;
  final int highMotionPenalty;
  final int impossibleChangePenalty;

  /// At lower trust, HR, SpO2 and anomaly components are gated to zero.
  final int minimumTrustForPhysiology;
}

/// The personal resting-HR baseline policy.
class PersonalBaselineConfig {
  const PersonalBaselineConfig({
    this.ewmaAlpha = 0.05,
    this.minimumSamples = 6,
    this.restAccelerationDeltaG = 0.12,
    this.restGyroscopeDps = 30,
    this.minimumHeartRate = 40,
    this.maximumHeartRate = 110,
    this.freezeAboveBaselineBpm = 30,
  });

  final double ewmaAlpha;
  final int minimumSamples;
  final double restAccelerationDeltaG;
  final double restGyroscopeDps;
  final double minimumHeartRate;
  final double maximumHeartRate;
  final double freezeAboveBaselineBpm;
}

/// Local fall workflow used if the wearable has no already-decided fall flag.
class FallWorkflowConfig {
  const FallWorkflowConfig({
    this.impactAccelerationG = 2.5,
    this.stillnessBandG = 0.12,
    this.stillnessDuration = const Duration(seconds: 2),
    this.verificationWindow = const Duration(seconds: 12),
    this.checkInWindow = const Duration(seconds: 30),
  });

  final double impactAccelerationG;
  final double stillnessBandG;
  final Duration stillnessDuration;
  final Duration verificationWindow;
  final Duration checkInWindow;
}

/// Scoring inputs. Positive component weights sum to 100 exactly.
class RiskFusionConfig {
  const RiskFusionConfig({
    this.anomalyWeight = 15,
    this.heartRateDeviationWeight = 25,
    this.spo2DeviationWeight = 30,
    this.heatExposureWeight = 20,
    this.activityWeight = 5,
    this.persistenceWeight = 5,
    this.heartRateDeviationForFullScoreBpm = 40,
    this.spo2NormalPercent = 96,
    this.spo2CriticalPercent = 88,
    this.heatStartC = 32,
    this.heatFullScoreC = 51,
    this.lightActivityAccelerationDeltaG = 0.08,
    this.lightActivityGyroscopeDps = 20,
    this.persistenceFullScore = const Duration(minutes: 6),
    this.criticalSpo2ScoreFloor = 80,
    this.minimumReportableContribution = 0.5,
  });

  final int anomalyWeight;
  final int heartRateDeviationWeight;
  final int spo2DeviationWeight;
  final int heatExposureWeight;
  final int activityWeight;
  final int persistenceWeight;
  final double heartRateDeviationForFullScoreBpm;
  final double spo2NormalPercent;
  final double spo2CriticalPercent;
  final double heatStartC;
  final double heatFullScoreC;
  final double lightActivityAccelerationDeltaG;
  final double lightActivityGyroscopeDps;
  final Duration persistenceFullScore;
  final double minimumReportableContribution;

  /// Trusted SpO2 at/below [spo2CriticalPercent] cannot be diluted by other
  /// benign inputs: it enters CRITICAL with at least this score.
  final int criticalSpo2ScoreFloor;
}

/// Alert-state entry, recovery and cooldown policy.
class RiskStateMachineConfig {
  const RiskStateMachineConfig({
    this.watchEnter = 20,
    this.warningEnter = 40,
    this.criticalEnter = 70,
    this.watchExit = 12,
    this.warningExit = 30,
    this.criticalExit = 55,
    this.watchEntryPersistence = Duration.zero,
    this.warningEntryPersistence = Duration.zero,
    this.criticalEntryPersistence = Duration.zero,
    this.watchRecovery = const Duration(seconds: 15),
    this.warningRecovery = const Duration(seconds: 30),
    this.criticalRecovery = const Duration(seconds: 60),
    this.watchMinimumDwell = const Duration(seconds: 15),
    this.warningMinimumDwell = const Duration(seconds: 30),
    this.criticalMinimumDwell = const Duration(seconds: 60),
  });

  /// Enter: score >=20 WATCH, >=40 WARNING, >=70 CRITICAL.
  final int watchEnter;
  final int warningEnter;
  final int criticalEnter;

  /// Exit: score must remain at/below this lower threshold.
  final int watchExit;
  final int warningExit;
  final int criticalExit;

  /// Consecutive time at the enter threshold. The prototype deliberately
  /// enters immediately; persistence is handled as a scoring input instead.
  final Duration watchEntryPersistence;
  final Duration warningEntryPersistence;
  final Duration criticalEntryPersistence;

  /// Consecutive recovery time before stepping down exactly one state.
  final Duration watchRecovery;
  final Duration warningRecovery;
  final Duration criticalRecovery;

  /// Minimum time the current state is held even if readings improve.
  final Duration watchMinimumDwell;
  final Duration warningMinimumDwell;
  final Duration criticalMinimumDwell;
}
