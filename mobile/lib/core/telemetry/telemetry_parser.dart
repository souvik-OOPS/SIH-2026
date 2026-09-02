import 'dart:convert';

import '../models/telemetry_frame.dart';

/// Converts untrusted replay or BLE payloads into the app's normalized model.
///
/// This is deliberately a boundary layer: UI, telemetry sources, and future
/// safety algorithms consume [TelemetryFrame] only. Invalid mandatory fields
/// reject a packet; unavailable optional sensor values remain null.
class TelemetryParser {
  const TelemetryParser._();

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
    } on Object {
      return null;
    }
  }

  static TelemetryFrame? tryParseMap(
    Map<String, dynamic> payload, {
    required TelemetrySourceType sourceType,
    required TelemetryConnectivity connectivity,
  }) {
    final timestamp = _timestamp(payload['ts'] ?? payload['timestamp']);
    final signalQuality = _normalizedQuality(
      payload['q'] ?? payload['signalQuality'],
    );
    if (timestamp == null || signalQuality == null) return null;

    return TelemetryFrame(
      timestamp: timestamp,
      heartRateBpm: _number(payload['hr'] ?? payload['heartRateBpm']),
      spo2Percent: _number(
        payload['spo2'] ?? payload['o2'] ?? payload['spo2Percent'],
      ),
      ambientTemperatureC: _number(
        payload['t'] ?? payload['at'] ?? payload['ambientTemperatureC'],
      ),
      humidityPercent: _number(
        payload['h'] ?? payload['rh'] ?? payload['humidityPercent'],
      ),
      accelerometerX: _number(payload['ax'] ?? payload['accelerometerX']),
      accelerometerY: _number(payload['ay'] ?? payload['accelerometerY']),
      accelerometerZ: _number(payload['az'] ?? payload['accelerometerZ']),
      gyroscopeX: _number(payload['gx'] ?? payload['gyroscopeX']),
      gyroscopeY: _number(payload['gy'] ?? payload['gyroscopeY']),
      gyroscopeZ: _number(payload['gz'] ?? payload['gyroscopeZ']),
      signalQuality: signalQuality,
      contactState: _contactState(
        payload['contact'] ?? payload['finger'] ?? payload['f'],
      ),
      sourceType: sourceType,
      connectivity: connectivity,
      sosPressed: _bool(payload['sos']),
      skinTemperatureC: _number(
        payload['skinTemp'] ??
            payload['skinTemperature'] ??
            payload['skinTemperatureC'],
      ),
      pm1MicrogramsPerM3: _number(payload['pm1'] ?? payload['pm1_0']),
      pm25MicrogramsPerM3: _number(payload['pm25'] ?? payload['pm2_5']),
      pm10MicrogramsPerM3: _number(payload['pm10']),
      batteryPercent: _percent(payload['battery'] ?? payload['batteryPercent']),
      movementDetected: _nullableBool(
        payload['movement'] ?? payload['movementDetected'],
      ),
      fallDetected: _nullableBool(payload['fall'] ?? payload['fallDetected']),
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

  static double? _normalizedQuality(Object? value) {
    final raw = _number(value);
    if (raw == null || raw < 0 || raw > 100) return null;
    return raw > 1 ? raw / 100 : raw;
  }

  static double? _percent(Object? value) {
    final parsed = _number(value);
    return parsed != null && parsed >= 0 && parsed <= 100 ? parsed : null;
  }

  static DateTime? _timestamp(Object? value) {
    if (value is num && value.isFinite) {
      try {
        final milliseconds = value.abs() > 100000000000
            ? value.toInt()
            : (value * 1000).round();
        return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
      } on Object {
        return null;
      }
    }
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  static ContactState _contactState(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'finger' || 'detected' || 'true' || '1' => ContactState.detected,
      'no_finger' || 'no-finger' || 'missing' || 'false' || '0' =>
        ContactState.noFinger,
      _ => ContactState.unknown,
    };
  }

  static bool _bool(Object? value) => _nullableBool(value) ?? false;

  static bool? _nullableBool(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    return switch (value.toString().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => null,
    };
  }
}
