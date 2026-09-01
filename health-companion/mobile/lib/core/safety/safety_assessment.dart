import '../../assistant/models/assistant_context.dart';

/// The verdict of the application's safety engine.
///
/// **Nothing produces this yet.** The Day 4-6 risk engine is the intended
/// producer; until it lands, callers pass `null` and the assistant reports
/// `riskLevel: not_computed` rather than inventing a level.
///
/// This exists now so the seam is fixed before the assistant is written
/// against it: the assistant consumes a decided verdict and may only explain
/// it. It can never compute, override, or downgrade one.
class SafetyAssessment {
  const SafetyAssessment({
    required this.riskLevel,
    this.fallDetected = false,
    this.movementAfterFall,
    this.activeWarnings = const [],
  });

  final RiskLevel riskLevel;
  final bool fallDetected;

  /// Null when no fall has been detected, so "no movement" is never implied
  /// by the absence of a fall.
  final bool? movementAfterFall;

  /// Human-readable warning ids already raised by the engine, e.g.
  /// `heat_stress`, `low_spo2`. The assistant explains these; it never adds
  /// to them.
  final List<String> activeWarnings;
}
