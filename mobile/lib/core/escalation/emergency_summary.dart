import '../../assistant/models/assistant_context.dart';
import '../models/telemetry_frame.dart';
import '../monitoring/health_alert.dart';
import '../monitoring/history_snapshot.dart';
import '../safety/safety_assessment.dart';
import '../safety/safety_guidance.dart';

/// A frozen, inspectable summary of local evidence. No generated text or sending.
class EmergencySummary {
  const EmergencySummary({
    required this.createdAt,
    required this.demo,
    required this.text,
  });
  final DateTime createdAt;
  final bool demo;
  final String text;

  factory EmergencySummary.capture({
    required DateTime now,
    required bool demo,
    required TelemetryFrame? frame,
    required SafetyAssessment? safety,
    required DateTime? lastReceivedAt,
    required TelemetryConnectivity connectivity,
    required bool running,
    required bool stale,
    HistorySnapshot? history,
    List<HealthAlert> alerts = const [],
  }) {
    final age = lastReceivedAt == null ? null : now.difference(lastReceivedAt);
    final fresh =
        frame != null &&
        age != null &&
        !age.isNegative &&
        age <= const Duration(seconds: 5) &&
        running &&
        !stale &&
        connectivity == TelemetryConnectivity.connected;
    final usable =
        fresh &&
        (safety?.sensorTrust.canUsePhysiology ?? false) &&
        frame.contactState != ContactState.noFinger;
    String stamp(DateTime at) => at.toUtc().toIso8601String();
    String number(double? value, String unit) =>
        value == null ? 'Unavailable' : '${value.toStringAsFixed(1)} $unit';
    final lines = <String>[
      'SWASTHYASHIELD — EMERGENCY SUMMARY',
      if (demo) 'DEMO / TEST DATA — not a real wearer incident',
      'Snapshot created (UTC): ${stamp(now)}',
      'Source: ${demo ? 'Replay demonstration' : 'Wearable BLE'}',
      'Monitoring: ${running ? 'Running' : 'Stopped'}; connection: ${connectivity.label}',
      'Last packet (UTC): ${lastReceivedAt == null ? 'Unavailable' : stamp(lastReceivedAt)}',
      'Data at capture: ${fresh ? 'Fresh' : 'No fresh readings — current condition is unknown'}',
      '',
      '${fresh ? 'Risk at capture' : 'Last computed risk'}: ${safety?.riskLevel.wireValue ?? 'NOT_COMPUTED'}',
      if (safety != null) 'Sensor signal: ${safety.sensorTrust.state.label}',
      'Heart rate: ${usable ? number(frame.heartRateBpm, 'bpm') : 'Unavailable — unreliable or missing fresh pulse data'}',
      'SpO2: ${usable ? number(frame.spo2Percent, '%') : 'Unavailable — unreliable or missing fresh pulse data'}',
      'Air temperature: ${fresh ? number(frame.ambientTemperatureC, '°C') : 'Unavailable'}',
      'Humidity: ${fresh ? number(frame.humidityPercent, '%') : 'Unavailable'}',
      'Air temperature is not body temperature.',
      'Fall workflow: ${switch (safety?.fallState) {
        FallWorkflowState.checkIn => 'Awaiting wearer check-in',
        FallWorkflowState.escalated => 'Check-in unanswered',
        FallWorkflowState.monitoring => 'No active fall check-in',
        null => 'Unavailable',
      }}',
      if (safety != null && safety.explanations.isNotEmpty) ...[
        '',
        '${fresh ? 'Evidence' : 'Evidence from the last assessment'}:',
        for (final reason in safety.explanations.take(5)) '- ${reason.detail}',
      ],
    ];
    final level = safety?.riskLevel ?? RiskLevel.notComputed;
    if (level.isElevated || (frame?.sosPressed ?? false)) {
      lines.addAll([
        '',
        'Suggested action: ${SafetyGuidance.action((frame?.sosPressed ?? false) ? RiskLevel.critical : level, safety?.reasons ?? [])}',
      ]);
    }
    final since = now.subtract(const Duration(minutes: 10));
    if (history != null &&
        history.demo == demo &&
        history.until == now &&
        history.since == since) {
      lines.addAll([
        '',
        'Previous 10 minutes of saved samples: ${history.samples}',
      ]);
      for (final metric in [HistoryMetric.heartRate, HistoryMetric.oxygen]) {
        final stat = history.metrics[metric];
        if (stat != null && stat.count > 0) {
          lines.add(
            '${metric.label}: mean ${number(stat.average, metric.unit)}; '
            'min ${number(stat.minimum, metric.unit)}; max ${number(stat.maximum, metric.unit)} '
            '(${stat.count} usable samples). Historical values, not current readings.',
          );
        }
      }
    }
    final recent =
        alerts
            .where(
              (a) =>
                  a.demo == demo && !a.at.isBefore(since) && !a.at.isAfter(now),
            )
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    lines.addAll(['', 'Recent alerts (previous 10 minutes, latest 5):']);
    if (recent.isEmpty) lines.add('None recorded in this period.');
    for (final alert in recent.take(5)) {
      lines.add(
        '- ${stamp(alert.at)} | ${alert.title} | ${alert.acknowledged ? 'Reviewed' : 'Not reviewed'}',
      );
    }
    lines.addAll([
      '',
      'Location is not collected by this app. Confirm it with the wearer.',
      'Prototype sensor information; this summary does not diagnose a condition.',
      'Preparing this summary does not notify a responder. Sharing requires choosing a recipient/app.',
    ]);
    return EmergencySummary(createdAt: now, demo: demo, text: lines.join('\n'));
  }
}
