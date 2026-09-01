import '../../core/models/telemetry_frame.dart';
import '../../core/safety/safety_assessment.dart';
import '../../core/telemetry/signal_quality.dart';
import '../models/assistant_context.dart';

/// Converts application state into the interpreted snapshot the assistant is
/// allowed to read.
///
/// Deliberately decoupled from BLE: it takes an already-parsed frame plus the
/// app's own derived state, so it works identically for replay, live BLE, or
/// no source at all. It never touches a radio, a stream, or a socket.
///
/// It also never *decides* anything about safety. [SafetyAssessment] is the
/// authority; when it is absent the risk level stays
/// [RiskLevel.notComputed].
class AssistantContextBuilder {
  const AssistantContextBuilder();

  AssistantContext build({
    TelemetryFrame? frame,
    SignalTier? signalTier,
    TelemetryConnectivity connectivity = TelemetryConnectivity.disconnected,
    bool isStale = false,
    SafetyAssessment? safety,
  }) {
    if (frame == null) {
      return AssistantContext.noTelemetry(
        connectivity: connectivity.label.toLowerCase(),
      );
    }

    return AssistantContext(
      heartRate: frame.heartRateBpm,
      spo2: frame.spo2Percent,
      temperature: frame.ambientTemperatureC,
      humidity: frame.humidityPercent,
      motionMagnitudeG: frame.accelerometerMagnitude,
      // Safety fields come only from the engine. With no engine, they stay
      // at their conservative defaults instead of being guessed from motion.
      fallDetected: safety?.fallDetected ?? false,
      movementDetected: safety?.movementAfterFall,
      signalQuality: _signalLabel(signalTier),
      riskLevel: safety?.riskLevel ?? RiskLevel.notComputed,
      activeWarnings: safety?.activeWarnings ?? const [],
      connectivity: connectivity.label.toLowerCase(),
      dataIsStale: isStale,
      contactState: _contactLabel(frame.contactState),
      sosPressed: frame.sosPressed,
      telemetryAvailable: true,
      sourceType: frame.sourceType.label.toLowerCase(),
    );
  }

  static String _signalLabel(SignalTier? tier) => switch (tier) {
    SignalTier.good => 'good',
    SignalTier.fair => 'fair',
    SignalTier.poor => 'poor',
    SignalTier.reacquiring => 'reacquiring',
    null => 'unknown',
  };

  static String _contactLabel(ContactState state) => switch (state) {
    ContactState.detected => 'detected',
    ContactState.noFinger => 'no_contact',
    ContactState.unknown => 'unknown',
  };
}
