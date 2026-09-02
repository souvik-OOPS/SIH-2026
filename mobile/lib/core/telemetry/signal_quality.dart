import '../models/telemetry_frame.dart';

/// Human-readable trust state for incoming sensor data.
///
/// This is data-quality information, not a medical assessment and not an
/// alert threshold. Safety features can choose how to handle it later.
enum SignalQualityLevel { excellent, good, fair, poor, invalid }

extension SignalQualityLevelLabel on SignalQualityLevel {
  String get label => switch (this) {
    SignalQualityLevel.excellent => 'EXCELLENT',
    SignalQualityLevel.good => 'GOOD',
    SignalQualityLevel.fair => 'FAIR',
    SignalQualityLevel.poor => 'POOR',
    SignalQualityLevel.invalid => 'INVALID',
  };

  String get wireValue => switch (this) {
    SignalQualityLevel.excellent => 'excellent',
    SignalQualityLevel.good => 'good',
    SignalQualityLevel.fair => 'fair',
    SignalQualityLevel.poor => 'poor',
    SignalQualityLevel.invalid => 'invalid',
  };
}

/// Explanation of the current data trust state.
class SignalQualityAssessment {
  const SignalQualityAssessment({required this.level, required this.reason});

  final SignalQualityLevel level;
  final String reason;

  /// False only when the app has no current telemetry it can trust at all.
  bool get isValid => level != SignalQualityLevel.invalid;
}

/// Normalized inputs supplied to a [SignalQualityModel].
///
/// Keeping the input independent from a screen or BLE class makes the
/// heuristic replaceable by a calibration- or model-based implementation.
class SignalQualityInput {
  const SignalQualityInput({
    required this.frame,
    required this.connectivity,
    required this.isStale,
  });

  final TelemetryFrame? frame;
  final TelemetryConnectivity connectivity;
  final bool isStale;
}

/// Contract for signal-quality logic. It has no UI dependency and can be
/// replaced without changing telemetry sources or dashboard widgets.
abstract interface class SignalQualityModel {
  SignalQualityAssessment assess(SignalQualityInput input);
}

/// Deterministic Day 1-2 baseline based only on the device's confidence,
/// finger-contact state, link state, and whether data has stopped arriving.
class HeuristicSignalQualityModel implements SignalQualityModel {
  const HeuristicSignalQualityModel();

  static const double excellentConfidence = 0.9;
  static const double goodConfidence = 0.7;
  static const double fairConfidence = 0.4;

  @override
  SignalQualityAssessment assess(SignalQualityInput input) {
    final frame = input.frame;
    if (frame == null) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.invalid,
        reason: 'No telemetry received yet.',
      );
    }
    if (input.connectivity != TelemetryConnectivity.connected) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.invalid,
        reason: 'Telemetry link is not connected.',
      );
    }
    if (input.isStale) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.invalid,
        reason: 'Telemetry has stopped updating.',
      );
    }
    if (frame.contactState == ContactState.noFinger) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.invalid,
        reason: 'No finger contact reported by the optical sensor.',
      );
    }

    final confidence = frame.signalQuality;
    if (confidence >= excellentConfidence) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.excellent,
        reason: 'High device-reported signal confidence.',
      );
    }
    if (confidence >= goodConfidence) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.good,
        reason: 'Good device-reported signal confidence.',
      );
    }
    if (confidence >= fairConfidence) {
      return const SignalQualityAssessment(
        level: SignalQualityLevel.fair,
        reason: 'Moderate device-reported signal confidence.',
      );
    }
    return const SignalQualityAssessment(
      level: SignalQualityLevel.poor,
      reason: 'Low device-reported signal confidence.',
    );
  }
}

/// Application-facing signal-quality boundary.
class SignalQualityService {
  SignalQualityService({SignalQualityModel? model})
    : _model = model ?? const HeuristicSignalQualityModel();

  final SignalQualityModel _model;

  SignalQualityAssessment assess({
    required TelemetryFrame? frame,
    required TelemetryConnectivity connectivity,
    required bool isStale,
  }) => _model.assess(
    SignalQualityInput(
      frame: frame,
      connectivity: connectivity,
      isStale: isStale,
    ),
  );
}
