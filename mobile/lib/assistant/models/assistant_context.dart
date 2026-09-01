import 'dart:convert';

/// Risk as decided by the application's RiskEngine — never by the LLM.
///
/// [notComputed] is the honest default for this build: the Day 4-6 RiskEngine
/// does not exist yet, so there is no authority to quote. The assistant says
/// "not computed" rather than inventing a level.
enum RiskLevel { notComputed, normal, watch, act, emergency }

extension RiskLevelLabel on RiskLevel {
  /// The wire value handed to the model and shown in the UI.
  String get wireValue => switch (this) {
    RiskLevel.notComputed => 'NOT_COMPUTED',
    RiskLevel.normal => 'NORMAL',
    RiskLevel.watch => 'WATCH',
    RiskLevel.act => 'ACT',
    RiskLevel.emergency => 'EMERGENCY',
  };

  /// Drives the "never minimize a dangerous state" rules in the prompt.
  bool get isElevated =>
      this == RiskLevel.watch ||
      this == RiskLevel.act ||
      this == RiskLevel.emergency;

  static RiskLevel fromWire(String value) => switch (value.toUpperCase()) {
    'NORMAL' => RiskLevel.normal,
    'WATCH' => RiskLevel.watch,
    'ACT' => RiskLevel.act,
    'EMERGENCY' => RiskLevel.emergency,
    _ => RiskLevel.notComputed,
  };
}

/// Languages the assistant answers in. Extensible: adding Bengali means
/// adding an enum value, a prompt line, and translated knowledge rows —
/// no engine or UI change.
enum AssistantLanguage { english, hindi }

extension AssistantLanguageInfo on AssistantLanguage {
  /// Stored on knowledge rows and used to filter retrieval.
  String get code => switch (this) {
    AssistantLanguage.english => 'en',
    AssistantLanguage.hindi => 'hi',
  };

  String get englishName => switch (this) {
    AssistantLanguage.english => 'English',
    AssistantLanguage.hindi => 'Hindi',
  };

  String get nativeName => switch (this) {
    AssistantLanguage.english => 'English',
    AssistantLanguage.hindi => 'हिंदी',
  };

  static AssistantLanguage fromCode(String code) =>
      code.toLowerCase().startsWith('hi')
      ? AssistantLanguage.hindi
      : AssistantLanguage.english;
}

/// The interpreted snapshot the assistant is allowed to see.
///
/// Deliberately NOT the raw telemetry stream: the assistant reads an
/// already-decided summary so it is never in the position of interpreting
/// sensor data itself. Every field is authoritative *input*; the model's
/// output is display text and is never read back into application state.
class AssistantContext {
  const AssistantContext({
    this.riskLevel = RiskLevel.notComputed,
    this.heartRate,
    this.spo2,
    this.temperature,
    this.ambientTemperature,
    this.humidity,
    this.signalQuality = 'unknown',
    this.fallDetected = false,
    this.movementDetected,
    this.timeToThresholdMinutes,
    this.reasons = const [],
    this.connectivity = 'unknown',
    this.dataIsStale = false,
    this.contactState = 'unknown',
    this.sosPressed = false,
    this.telemetryAvailable = true,
    this.sourceType = 'unknown',
  });

  /// No telemetry at all — BLE down, or nothing received yet.
  const AssistantContext.noTelemetry({
    this.connectivity = 'disconnected',
    this.sourceType = 'unknown',
  }) : riskLevel = RiskLevel.notComputed,
       heartRate = null,
       spo2 = null,
       temperature = null,
       ambientTemperature = null,
       humidity = null,
       signalQuality = 'unknown',
       fallDetected = false,
       movementDetected = null,
       timeToThresholdMinutes = null,
       reasons = const [],
       dataIsStale = false,
       contactState = 'unknown',
       sosPressed = false,
       telemetryAvailable = false;

  final RiskLevel riskLevel;
  final double? heartRate;
  final double? spo2;

  /// Body temperature in °C. Null on this hardware — no body-temperature
  /// sensor is fitted — and reported as unavailable rather than substituted
  /// with the ambient reading.
  final double? temperature;

  /// Ambient air temperature in °C, from the DHT22.
  final double? ambientTemperature;
  final double? humidity;

  /// One of: good, fair, poor, reacquiring, unknown.
  final String signalQuality;
  final bool fallDetected;
  final bool? movementDetected;

  /// Minutes until the RiskEngine projects a threshold breach, when it
  /// computes one. Null means "not projected", never "no risk".
  final int? timeToThresholdMinutes;

  /// Machine-readable reason ids from the RiskEngine, e.g.
  /// `heat_strain_rising`. The assistant explains these; it never adds to
  /// them.
  final List<String> reasons;

  final String connectivity;
  final bool dataIsStale;
  final String contactState;
  final bool sosPressed;
  final bool telemetryAvailable;
  final String sourceType;

  /// True when readings must be presented as untrustworthy.
  bool get readingsUnreliable =>
      !telemetryAvailable ||
      dataIsStale ||
      signalQuality == 'poor' ||
      signalQuality == 'reacquiring';

  Map<String, dynamic> toJson() => {
    'riskLevel': riskLevel.wireValue,
    'heartRate': heartRate,
    'spo2': spo2,
    'temperature': temperature,
    'ambientTemperature': ambientTemperature,
    'humidity': humidity,
    'signalQuality': signalQuality,
    'fallDetected': fallDetected,
    'movementDetected': movementDetected,
    'timeToThresholdMinutes': timeToThresholdMinutes,
    'reasons': reasons,
    'connectivity': connectivity,
    'dataIsStale': dataIsStale,
    'contactState': contactState,
    'sosPressed': sosPressed,
    'telemetryAvailable': telemetryAvailable,
    'source': sourceType,
  };

  /// Compact, deterministic rendering for the prompt. Nulls are written as
  /// "unavailable" rather than dropped, so the model cannot mistake a missing
  /// reading for one it may invent.
  String toPromptBlock() {
    String number(double? value, String unit, {int decimals = 0}) =>
        value == null
        ? 'unavailable'
        : '${value.toStringAsFixed(decimals)}$unit';

    return <String>[
      'riskLevel: ${riskLevel.wireValue}',
      'heartRate: ${number(heartRate, ' bpm')}',
      'spo2: ${number(spo2, '%')}',
      'bodyTemperature: ${number(temperature, ' C', decimals: 1)}',
      'ambientTemperature: ${number(ambientTemperature, ' C', decimals: 1)}',
      'humidity: ${number(humidity, '%')}',
      'signalQuality: $signalQuality',
      'fallDetected: $fallDetected',
      'movementDetected: ${movementDetected ?? 'unknown'}',
      'timeToThresholdMinutes: ${timeToThresholdMinutes ?? 'not projected'}',
      'reasons: ${reasons.isEmpty ? 'none' : reasons.join(', ')}',
      'connectivity: $connectivity',
      'dataIsStale: $dataIsStale',
      'sensorContact: $contactState',
      'telemetryAvailable: $telemetryAvailable',
      'telemetrySource: $sourceType',
    ].join('\n');
  }

  @override
  String toString() => jsonEncode(toJson());
}
