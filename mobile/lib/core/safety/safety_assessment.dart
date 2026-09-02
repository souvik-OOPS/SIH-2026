import '../../assistant/models/assistant_context.dart';

/// Immutable verdict emitted by the Day 6 RiskEngine.
///
/// The assistant consumes this decided verdict and may only explain it. There
/// is no path from generated text back into risk state.
class SafetyAssessment {
  const SafetyAssessment({
    required this.riskLevel,
    this.score = 0,
    this.sensorTrust = const SensorTrustAssessment.reliable(),
    this.fallState = FallWorkflowState.monitoring,
    this.fallDetected = false,
    this.movementAfterFall,
    this.timeToThresholdMinutes,
    this.reasons = const [],
    this.explanations = const [],
    this.baselineHeartRate,
    this.baselineReady = false,
    this.heatIndexC,
  });

  final RiskLevel riskLevel;
  final int score;
  final SensorTrustAssessment sensorTrust;
  final FallWorkflowState fallState;
  final bool fallDetected;

  /// Null when no fall was detected, so "no movement" is never implied by
  /// the absence of a fall.
  final bool? movementAfterFall;

  /// Minutes until a projected threshold breach, when the engine computes
  /// one. Null means "not projected", never "no risk".
  final int? timeToThresholdMinutes;

  /// Machine-readable reason ids consumed by the assistant.
  final List<String> reasons;

  /// Human-readable facts used by the monitoring UI.
  final List<RiskReason> explanations;
  final double? baselineHeartRate;
  final bool baselineReady;
  final double? heatIndexC;
}

enum SensorTrustState { reliable, degraded, reacquiring, stale }

extension SensorTrustStateLabel on SensorTrustState {
  String get label => switch (this) {
    SensorTrustState.reliable => 'RELIABLE',
    SensorTrustState.degraded => 'DEGRADED',
    SensorTrustState.reacquiring => 'REACQUIRING',
    SensorTrustState.stale => 'STALE',
  };
}

class SensorTrustAssessment {
  const SensorTrustAssessment({
    required this.state,
    required this.score,
    this.reasons = const [],
  });

  const SensorTrustAssessment.reliable()
    : state = SensorTrustState.reliable,
      score = 100,
      reasons = const ['Reliable sensor signal.'];

  SensorTrustAssessment.reacquiring(String reason)
    : state = SensorTrustState.reacquiring,
      score = 0,
      reasons = [reason];

  SensorTrustAssessment.stale(String reason)
    : state = SensorTrustState.stale,
      score = 0,
      reasons = [reason];

  final SensorTrustState state;
  final int score;
  final List<String> reasons;

  bool get canUsePhysiology =>
      state == SensorTrustState.reliable || state == SensorTrustState.degraded;
}

enum FallWorkflowState { monitoring, checkIn, escalated }

class RiskReason {
  const RiskReason({
    required this.code,
    required this.detail,
    this.contribution = 0,
  });

  final String code;
  final String detail;
  final int contribution;
}
