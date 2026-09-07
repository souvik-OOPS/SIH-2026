import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_context.dart';
import 'package:swasthyashield_edge/core/escalation/emergency_summary.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/monitoring/health_alert.dart';
import 'package:swasthyashield_edge/core/safety/safety_assessment.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';

void main() {
  final now = DateTime.utc(2026, 9, 7, 12);
  final frame = TelemetryParser.tryParseMap(
    {
      'hr': 123,
      'spo2': 97,
      'at': 31,
      'rh': 60,
      'q': 95,
      'contact': 'finger',
      'timestamp': now.toIso8601String(),
    },
    sourceType: TelemetrySourceType.ble,
    connectivity: TelemetryConnectivity.connected,
  )!;
  EmergencySummary capture({
    DateTime? last,
    bool running = true,
    bool demo = false,
    bool stale = false,
    SafetyAssessment safety = const SafetyAssessment(
      riskLevel: RiskLevel.normal,
    ),
    List<HealthAlert> alerts = const [],
  }) => EmergencySummary.capture(
    now: now,
    demo: demo,
    frame: frame,
    safety: safety,
    lastReceivedAt: last ?? now,
    connectivity: TelemetryConnectivity.connected,
    running: running,
    stale: stale,
    alerts: alerts,
  );

  test(
    'summary is stamped and reports fresh usable readings without delivery claims',
    () {
      final text = capture().text;
      expect(text, contains(now.toIso8601String()));
      expect(text, contains('Heart rate: 123.0 bpm'));
      expect(text, contains('SpO2: 97.0 %'));
      expect(text, contains('Air temperature is not body temperature'));
      expect(text, contains('does not notify a responder'));
    },
  );
  test(
    'stopped or old packets hide current vitals even before the stale timer runs',
    () {
      for (final summary in [
        capture(running: false),
        capture(last: now.subtract(const Duration(seconds: 6))),
        capture(stale: true),
      ]) {
        expect(summary.text, isNot(contains('123.0')));
        expect(summary.text, contains('Last computed risk: NORMAL'));
        expect(summary.text, contains('current condition is unknown'));
      }
    },
  );
  test('bad pulse still allows fresh environment and a fall stays urgent', () {
    final safety = SafetyAssessment(
      riskLevel: RiskLevel.critical,
      fallState: FallWorkflowState.escalated,
      fallDetected: true,
      reasons: const ['fall_no_response'],
      sensorTrust: SensorTrustAssessment.reacquiring('No contact'),
    );
    final text = capture(safety: safety).text;
    expect(text, isNot(contains('123.0')));
    expect(text, contains('Air temperature: 31.0'));
    expect(text, contains('Check-in unanswered'));
    expect(text, contains('Get help now'));
  });
  test(
    'demo summaries are labelled and exclude live, old and future alerts',
    () {
      HealthAlert alert(String title, bool demo, DateTime at) => HealthAlert(
        id: title,
        type: 'fall',
        title: title,
        body: '',
        at: at,
        critical: true,
        demo: demo,
      );
      final text = capture(
        demo: true,
        alerts: [
          alert('demo incident', true, now),
          alert('live incident', false, now),
          alert('old incident', true, now.subtract(const Duration(hours: 1))),
          alert('future incident', true, now.add(const Duration(seconds: 1))),
        ],
      ).text;
      expect(text, contains('DEMO / TEST DATA'));
      expect(text, contains('demo incident'));
      expect(text, isNot(contains('live incident')));
      expect(text, isNot(contains('old incident')));
      expect(text, isNot(contains('future incident')));
    },
  );
}
