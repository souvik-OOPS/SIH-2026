import 'dart:math' as math;

enum TelemetrySourceType { replay, ble }

enum TelemetryConnectivity { disconnected, connecting, connected, offline }

enum ContactState { detected, noFinger, unknown }

extension TelemetrySourceTypeLabel on TelemetrySourceType {
  String get label => switch (this) {
    TelemetrySourceType.replay => 'Replay',
    TelemetrySourceType.ble => 'BLE',
  };
}

extension TelemetryConnectivityLabel on TelemetryConnectivity {
  String get label => switch (this) {
    TelemetryConnectivity.disconnected => 'Disconnected',
    TelemetryConnectivity.connecting => 'Connecting',
    TelemetryConnectivity.connected => 'Connected',
    TelemetryConnectivity.offline => 'Offline',
  };
}

extension ContactStateLabel on ContactState {
  String get label => switch (this) {
    ContactState.detected => 'Finger detected',
    ContactState.noFinger => 'No finger contact',
    ContactState.unknown => 'Contact unknown',
  };
}

/// A single normalized packet, shared by replay and live BLE telemetry.
///
/// Values absent from the current device protocol stay null. This lets future
/// sensors be introduced without manufacturing values on the phone.
class TelemetryFrame {
  const TelemetryFrame({
    required this.timestamp,
    required this.heartRateBpm,
    required this.spo2Percent,
    required this.ambientTemperatureC,
    required this.humidityPercent,
    required this.accelerometerX,
    required this.accelerometerY,
    required this.accelerometerZ,
    required this.gyroscopeX,
    required this.gyroscopeY,
    required this.gyroscopeZ,
    required this.signalQuality,
    required this.contactState,
    required this.sourceType,
    required this.connectivity,
    required this.sosPressed,
    this.skinTemperatureC,
    this.pm1MicrogramsPerM3,
    this.pm25MicrogramsPerM3,
    this.pm10MicrogramsPerM3,
    this.batteryPercent,
    this.movementDetected,
    this.fallDetected,
  });

  final DateTime timestamp;
  final double? heartRateBpm;
  final double? spo2Percent;
  final double? ambientTemperatureC;
  final double? humidityPercent;
  final double? accelerometerX;
  final double? accelerometerY;
  final double? accelerometerZ;
  final double? gyroscopeX;
  final double? gyroscopeY;
  final double? gyroscopeZ;

  /// Normalized to 0.0–1.0. The compact firmware protocol may send 0–100.
  final double signalQuality;
  final ContactState contactState;
  final TelemetrySourceType sourceType;
  final TelemetryConnectivity connectivity;
  final bool sosPressed;

  /// Optional device capabilities. The Day 2 ESP32 packet does not currently
  /// supply these, so callers must treat null as unavailable rather than zero.
  final double? skinTemperatureC;
  final double? pm1MicrogramsPerM3;
  final double? pm25MicrogramsPerM3;
  final double? pm10MicrogramsPerM3;
  final double? batteryPercent;
  final bool? movementDetected;
  final bool? fallDetected;

  double? get accelerometerMagnitude {
    final x = accelerometerX;
    final y = accelerometerY;
    final z = accelerometerZ;
    if (x == null || y == null || z == null) return null;
    return math.sqrt(x * x + y * y + z * z);
  }

  TelemetryFrame copyWith({
    DateTime? timestamp,
    TelemetryConnectivity? connectivity,
  }) {
    return TelemetryFrame(
      timestamp: timestamp ?? this.timestamp,
      heartRateBpm: heartRateBpm,
      spo2Percent: spo2Percent,
      ambientTemperatureC: ambientTemperatureC,
      humidityPercent: humidityPercent,
      accelerometerX: accelerometerX,
      accelerometerY: accelerometerY,
      accelerometerZ: accelerometerZ,
      gyroscopeX: gyroscopeX,
      gyroscopeY: gyroscopeY,
      gyroscopeZ: gyroscopeZ,
      signalQuality: signalQuality,
      contactState: contactState,
      sourceType: sourceType,
      connectivity: connectivity ?? this.connectivity,
      sosPressed: sosPressed,
      skinTemperatureC: skinTemperatureC,
      pm1MicrogramsPerM3: pm1MicrogramsPerM3,
      pm25MicrogramsPerM3: pm25MicrogramsPerM3,
      pm10MicrogramsPerM3: pm10MicrogramsPerM3,
      batteryPercent: batteryPercent,
      movementDetected: movementDetected,
      fallDetected: fallDetected,
    );
  }
}
