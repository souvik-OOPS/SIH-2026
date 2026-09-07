import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/monitoring/health_alert_engine.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';
import 'package:swasthyashield_edge/core/safety/safety_assessment.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_context.dart';

void main() {
  final start = DateTime(2026, 9, 7);
  TelemetryFrame frame({double hr = 140, double o2 = 97}) =>
      TelemetryParser.tryParseMap(
        {
          'timestamp': start.toIso8601String(),
          'hr': hr,
          'spo2': o2,
          'q': 95,
          'contact': 'finger',
          'ax': 0,
          'ay': 0,
          'az': 1,
        },
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      )!;
  const normal = SafetyAssessment(riskLevel: RiskLevel.normal);
  test(
    'high HR must persist, repeats are limited, and critical O2 bypasses cooldown',
    () {
      final engine = HealthAlertEngine();
      final emitted = <String>[];
      for (var s = 0; s <= 90; s++) {
        final alerts = engine.assess(
          frame: frame(o2: s >= 40 ? 85 : 97),
          safety: normal,
          stale: false,
          connectivity: TelemetryConnectivity.connected,
          now: start.add(Duration(seconds: s)),
        );
        if (s < 30) expect(alerts, isEmpty);
        emitted.addAll(alerts.map((a) => a.type));
      }
      expect(emitted.where((t) => t == 'hr_high').length, 1);
      expect(emitted.where((t) => t == 'o2_critical').length, 1);
    },
  );
  test('a normal sample resets sustain timing', () {
    final engine = HealthAlertEngine();
    for (var s = 0; s < 50; s++) {
      final alerts = engine.assess(
        frame: frame(hr: s == 25 ? 72 : 140),
        safety: normal,
        stale: false,
        connectivity: TelemetryConnectivity.connected,
        now: start.add(Duration(seconds: s)),
      );
      expect(alerts, isEmpty);
    }
  });
  test('unreliable pulse does not produce HR or oxygen alerts', () {
    final engine = HealthAlertEngine();
    final poor = SafetyAssessment(
      riskLevel: RiskLevel.normal,
      sensorTrust: SensorTrustAssessment.reacquiring('No contact'),
    );
    for (var s = 0; s < 70; s++) {
      final alerts = engine.assess(
        frame: frame(o2: 80),
        safety: poor,
        stale: false,
        connectivity: TelemetryConnectivity.connected,
        now: start.add(Duration(seconds: s)),
      );
      expect(
        alerts.any((a) => a.type.startsWith('hr') || a.type.startsWith('o2')),
        isFalse,
      );
    }
  });
  test('disconnect produces connection alert, never stale vital alarms', () {
    final engine = HealthAlertEngine();
    final types = <String>[];
    for (var s = 0; s <= 20; s++) {
      types.addAll(
        engine
            .assess(
              frame: frame(o2: 80),
              safety: normal,
              stale: true,
              connectivity: TelemetryConnectivity.disconnected,
              now: start.add(Duration(seconds: s)),
            )
            .map((a) => a.type),
      );
    }
    expect(types, ['connection']);
  });
  test('low HR and moderately low O2 receive sustained alerts', () {
    final engine = HealthAlertEngine();
    final types = <String>[];
    for (var s = 0; s <= 30; s++) {
      types.addAll(
        engine
            .assess(
              frame: frame(hr: 45, o2: 90),
              safety: normal,
              stale: false,
              connectivity: TelemetryConnectivity.connected,
              now: start.add(Duration(seconds: s)),
            )
            .map((a) => a.type),
      );
    }
    expect(types, containsAll(['hr_low', 'o2_low']));
  });
}
