import 'dart:convert';
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

/// A single normalized packet, shared by replay and future BLE telemetry.
///
/// The parser accepts the compact ESP32 contract (`hr`, `o2`, `t`, `h`, `ax`)
/// as well as the replay schema and descriptive field names used by tests.
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
    );
  }

  static TelemetryFrame? tryParseJson(
    String payload, {
    required TelemetrySourceType sourceType,
    required TelemetryConnectivity connectivity,
  }) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return tryParseMap(
        Map<String, dynamic>.from(decoded),
        sourceType: sourceType,
        connectivity: connectivity,
      );
    } on FormatException {
      return null;
    }
  }

  static TelemetryFrame? tryParseMap(
    Map<String, dynamic> payload, {
    required TelemetrySourceType sourceType,
    required TelemetryConnectivity connectivity,
  }) {
    final timestamp = _timestamp(payload['ts'] ?? payload['timestamp']);
    final ambientTemperature = _number(
      payload['t'] ?? payload['at'] ?? payload['ambientTemperatureC'],
    );
    final humidity = _number(
      payload['h'] ?? payload['rh'] ?? payload['humidityPercent'],
    );
    final ax = _number(payload['ax'] ?? payload['accelerometerX']);
    final ay = _number(payload['ay'] ?? payload['accelerometerY']);
    final az = _number(payload['az'] ?? payload['accelerometerZ']);
    final gx = _number(payload['gx'] ?? payload['gyroscopeX']);
    final gy = _number(payload['gy'] ?? payload['gyroscopeY']);
    final gz = _number(payload['gz'] ?? payload['gyroscopeZ']);
    final rawQuality = _number(payload['q'] ?? payload['signalQuality']);

    if (timestamp == null || rawQuality == null) {
      return null;
    }

    final normalizedQuality = rawQuality > 1 ? rawQuality / 100 : rawQuality;
    if (!normalizedQuality.isFinite) return null;

    return TelemetryFrame(
      timestamp: timestamp,
      heartRateBpm: _number(payload['hr'] ?? payload['heartRateBpm']),
      spo2Percent: _number(
        payload['spo2'] ?? payload['o2'] ?? payload['spo2Percent'],
      ),
      ambientTemperatureC: ambientTemperature,
      humidityPercent: humidity,
      accelerometerX: ax,
      accelerometerY: ay,
      accelerometerZ: az,
      gyroscopeX: gx,
      gyroscopeY: gy,
      gyroscopeZ: gz,
      signalQuality: normalizedQuality.clamp(0, 1).toDouble(),
      contactState: _contactState(
        payload['contact'] ?? payload['finger'] ?? payload['f'],
      ),
      sourceType: sourceType,
      connectivity: connectivity,
      sosPressed: _bool(payload['sos']),
    );
  }

  static double? _number(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      return parsed != null && parsed.isFinite ? parsed : null;
    }
    return null;
  }

  static DateTime? _timestamp(Object? value) {
    if (value is num) {
      final milliseconds = value.abs() > 100000000000
          ? value.toInt()
          : (value * 1000).round();
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    }
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }

  static ContactState _contactState(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'finger' || 'detected' || 'true' || '1' => ContactState.detected,
      'no_finger' ||
      'no-finger' ||
      'missing' ||
      'false' ||
      '0' => ContactState.noFinger,
      _ => ContactState.unknown,
    };
  }

  static bool _bool(Object? value) {
    return value is bool
        ? value
        : value is num
        ? value != 0
        : value?.toString().toLowerCase() == 'true';
  }
}
