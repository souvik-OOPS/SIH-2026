import '../../assistant/models/assistant_context.dart';

/// The verdict of the application's RiskEngine.
///
/// **Nothing produces this yet.** The Day 4-6 RiskEngine is the intended
/// producer; until it lands, callers pass `null` and the assistant reports
/// `riskLevel: NOT_COMPUTED` rather than inventing a level.
///
/// The seam is fixed now, before the assistant is written against it: the
/// assistant consumes a decided verdict and may only explain it. It can never
/// compute, override, or downgrade one. This class is deliberately immutable
/// and has no setters — there is no path by which generated text could reach
/// it.
class SafetyAssessment {
  const SafetyAssessment({
    required this.riskLevel,
    this.fallDetected = false,
    this.movementAfterFall,
    this.timeToThresholdMinutes,
    this.reasons = const [],
  });

  final RiskLevel riskLevel;
  final bool fallDetected;

  /// Null when no fall was detected, so "no movement" is never implied by the
  /// absence of a fall.
  final bool? movementAfterFall;

  /// Minutes until a projected threshold breach, when the engine computes
  /// one. Null means "not projected", never "no risk".
  final int? timeToThresholdMinutes;

  /// Machine-readable reason ids, e.g. `heart_rate_above_baseline`,
  /// `heat_strain_rising`. The assistant explains these; it never adds to
  /// them.
  final List<String> reasons;
}
