import 'dart:convert';

/// Risk as decided by the application's safety engine — never by the LLM.
///
/// [notComputed] is the honest default for this build: the Day 4-6 risk
/// engine does not exist yet, so there is no authority to quote. The
/// assistant must say "not computed" rather than guess a level.
enum RiskLevel { notComputed, normal, caution, warning, critical }

extension RiskLevelLabel on RiskLevel {
  String get wireValue => switch (this) {
    RiskLevel.notComputed => 'not_computed',
    RiskLevel.normal => 'normal',
    RiskLevel.caution => 'caution',
    RiskLevel.warning => 'warning',
    RiskLevel.critical => 'critical',
  };

  /// Drives the "never say a dangerous state is safe" rule in the prompt.
  bool get isElevated =>
      this == RiskLevel.warning || this == RiskLevel.critical;
}

/// The interpreted snapshot the assistant is allowed to see.
///
/// Deliberately NOT the raw telemetry stream: the assistant reads an
/// already-decided summary, at low frequency, so it can never be in the
/// position of interpreting sensor data itself.
///
/// Every field here is authoritative input to the model. The model's output
/// is display text only and is never read back into application state.
class AssistantContext {
  const AssistantContext({
    this.heartRate,
    this.spo2,
    this.temperature,
    this.humidity,
    this.motionMagnitudeG,
    this.fallDetected = false,
    this.movementDetected,
    this.signalQuality = 'unknown',
    this.riskLevel = RiskLevel.notComputed,
    this.activeWarnings = const [],
    this.connectivity = 'unknown',
    this.dataIsStale = false,
    this.contactState = 'unknown',
    this.sosPressed = false,
    this.telemetryAvailable = true,
    this.sourceType = 'unknown',
  });

  /// A context with no telemetry at all — BLE down, or nothing received yet.
  const AssistantContext.noTelemetry({
    this.connectivity = 'disconnected',
    this.sourceType = 'unknown',
  }) : heartRate = null,
       spo2 = null,
       temperature = null,
       humidity = null,
       motionMagnitudeG = null,
       fallDetected = false,
       movementDetected = null,
       signalQuality = 'unknown',
       riskLevel = RiskLevel.notComputed,
       activeWarnings = const [],
       dataIsStale = false,
       contactState = 'unknown',
       sosPressed = false,
       telemetryAvailable = false;

  final double? heartRate;
  final double? spo2;

  /// Ambient air temperature in °C. Never body temperature — the sensor
  /// measures the air around the wearer.
  final double? temperature;
  final double? humidity;
  final double? motionMagnitudeG;

  final bool fallDetected;
  final bool? movementDetected;

  /// One of: good, fair, poor, reacquiring, unknown.
  final String signalQuality;
  final RiskLevel riskLevel;
  final List<String> activeWarnings;

  final String connectivity;
  final bool dataIsStale;
  final String contactState;
  final bool sosPressed;
  final bool telemetryAvailable;
  final String sourceType;

  /// True when readings should be presented as untrustworthy.
  bool get readingsUnreliable =>
      !telemetryAvailable ||
      dataIsStale ||
      signalQuality == 'poor' ||
      signalQuality == 'reacquiring';

  Map<String, dynamic> toJson() => {
    'heartRate': heartRate,
    'spo2': spo2,
    'ambientTemperature': temperature,
    'humidity': humidity,
    'motionMagnitudeG': motionMagnitudeG,
    'fallDetected': fallDetected,
    'movementDetected': movementDetected,
    'signalQuality': signalQuality,
    'riskLevel': riskLevel.wireValue,
    'activeWarnings': activeWarnings,
    'connectivity': connectivity,
    'dataIsStale': dataIsStale,
    'contactState': contactState,
    'sosPressed': sosPressed,
    'telemetryAvailable': telemetryAvailable,
    'source': sourceType,
  };

  /// Compact, deterministic rendering for the prompt. Nulls are written as
  /// "unavailable" rather than dropped, so the model cannot mistake a missing
  /// reading for one it is free to invent.
  String toPromptBlock() {
    String number(double? value, String unit, {int decimals = 0}) =>
        value == null
        ? 'unavailable'
        : '${value.toStringAsFixed(decimals)}$unit';

    final lines = <String>[
      'heartRate: ${number(heartRate, ' bpm')}',
      'spo2: ${number(spo2, '%')}',
      'ambientTemperature: ${number(temperature, ' C', decimals: 1)}'
          '  (air temperature, not body temperature)',
      'humidity: ${number(humidity, '%')}',
      'motion: ${number(motionMagnitudeG, ' g', decimals: 2)}',
      'fallDetected: $fallDetected',
      'movementDetected: ${movementDetected ?? 'unknown'}',
      'signalQuality: $signalQuality',
      'riskLevel: ${riskLevel.wireValue}',
      'activeWarnings: ${activeWarnings.isEmpty ? 'none' : activeWarnings.join(', ')}',
      'connectivity: $connectivity',
      'dataIsStale: $dataIsStale',
      'sensorContact: $contactState',
      'telemetryAvailable: $telemetryAvailable',
      'telemetrySource: $sourceType',
    ];
    return lines.join('\n');
  }

  @override
  String toString() => jsonEncode(toJson());
}
