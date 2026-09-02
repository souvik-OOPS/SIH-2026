import '../../core/models/telemetry_frame.dart';
import '../../core/safety/safety_assessment.dart';
import '../../core/telemetry/signal_quality.dart';
import '../models/assistant_context.dart';

/// Converts application state into the interpreted snapshot the assistant is
/// allowed to read.
///
/// Decoupled from BLE: it takes an already-parsed frame plus the app's own
/// derived state, so it behaves identically for replay, live BLE, or no
/// source at all. It never touches a radio, a stream, or a socket.
///
/// It also never *decides* anything about safety. [SafetyAssessment] is the
/// sole authority; when it is absent the risk level stays
/// [RiskLevel.notComputed] and every safety field keeps its conservative
/// default. This is a pure function of its inputs — the same inputs always
/// produce the same context, no matter what any model said in between.
class AssistantContextBuilder {
  const AssistantContextBuilder();

  AssistantContext build({
    TelemetryFrame? frame,
    SignalQualityLevel? signalTier,
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
      // Safety fields come only from the engine. With no engine they stay at
      // their defaults rather than being inferred from motion or vitals.
      riskLevel: safety?.riskLevel ?? RiskLevel.notComputed,
      fallDetected: safety?.fallDetected ?? false,
      movementDetected: safety?.movementAfterFall,
      timeToThresholdMinutes: safety?.timeToThresholdMinutes,
      reasons: safety?.reasons ?? const [],
      heartRate: frame.heartRateBpm,
      spo2: frame.spo2Percent,
      // No body-temperature sensor is fitted on this hardware, so this stays
      // null. The ambient reading is never promoted into its place.
      temperature: null,
      ambientTemperature: frame.ambientTemperatureC,
      humidity: frame.humidityPercent,
      signalQuality: _signalLabel(signalTier),
      connectivity: connectivity.label.toLowerCase(),
      dataIsStale: isStale,
      contactState: _contactLabel(frame.contactState),
      sosPressed: frame.sosPressed,
      telemetryAvailable: true,
      sourceType: frame.sourceType.label.toLowerCase(),
    );
  }

  static String _signalLabel(SignalQualityLevel? tier) => switch (tier) {
    SignalQualityLevel.excellent => 'excellent',
    SignalQualityLevel.good => 'good',
    SignalQualityLevel.fair => 'fair',
    SignalQualityLevel.poor => 'poor',
    SignalQualityLevel.invalid => 'invalid',
    null => 'unknown',
  };

  static String _contactLabel(ContactState state) => switch (state) {
    ContactState.detected => 'detected',
    ContactState.noFinger => 'no_contact',
    ContactState.unknown => 'unknown',
  };
}
