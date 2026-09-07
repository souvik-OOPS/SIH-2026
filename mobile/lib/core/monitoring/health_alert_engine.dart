import '../../assistant/models/assistant_context.dart';
import '../models/telemetry_frame.dart';
import '../safety/safety_assessment.dart';
import '../safety/safety_guidance.dart';
import 'health_alert.dart';

/// Notification policy, independent of chat and of screen lifecycle.
/// Prototype defaults mirror the project's sustained vital alerts.
class HealthAlertEngine {
  HealthAlertEngine({
    this.sustain = const Duration(seconds: 30),
    this.cooldown = const Duration(minutes: 5),
    this.maxGap = const Duration(seconds: 6),
  });
  final Duration sustain, cooldown, maxGap;
  final Map<String, DateTime> _since = {}, _sent = {};
  DateTime? _previous;
  int _sequence = 0;

  void reset() {
    _since.clear();
    _sent.clear();
    _previous = null;
  }

  List<HealthAlert> assess({
    required TelemetryFrame? frame,
    required SafetyAssessment? safety,
    required bool stale,
    required TelemetryConnectivity connectivity,
    required DateTime now,
  }) {
    if (frame == null || safety == null) return [];
    final alerts = <HealthAlert>[];
    if (_previous != null && now.difference(_previous!) > maxGap) {
      _since.clear();
    }
    _previous = now;
    final fresh = !stale && connectivity == TelemetryConnectivity.connected;
    final trust = fresh && safety.sensorTrust.canUsePhysiology;
    final active = <String>{};
    void condition(
      String type,
      bool applies,
      String title,
      String body, {
      bool critical = false,
      Duration? delay,
    }) {
      if (!applies) return;
      active.add(type);
      _since.putIfAbsent(type, () => now);
      if (now.difference(_since[type]!) < (delay ?? sustain)) return;
      final last = _sent[type];
      if (last != null && now.difference(last) < cooldown) return;
      _sent[type] = now;
      alerts.add(
        HealthAlert(
          id: '${now.microsecondsSinceEpoch}-${_sequence++}',
          type: type,
          title: title,
          body: body,
          at: now,
          critical: critical,
          demo: frame.sourceType == TelemetrySourceType.replay,
        ),
      );
    }

    final hr = frame.heartRateBpm;
    final o2 = frame.spo2Percent;
    condition(
      'hr_high',
      trust && hr != null && hr > 120,
      'Heart rate remains high',
      'Heart rate ${hr?.round()} bpm for at least ${sustain.inSeconds}s. Rest and check the reading. Seek help if you feel unwell.',
    );
    condition(
      'hr_low',
      trust && hr != null && hr < 50,
      'Heart rate remains low',
      'Heart rate ${hr?.round()} bpm for at least ${sustain.inSeconds}s. Recheck sensor contact. Seek help if you feel unwell.',
    );
    condition(
      'o2_low',
      trust && o2 != null && o2 < 92 && o2 > 88,
      'Oxygen reading remains low',
      'SpO2 ${o2?.round()}% for at least ${sustain.inSeconds}s. Recheck the reading and seek help if it stays low.',
    );
    condition(
      'o2_critical',
      trust && o2 != null && o2 <= 88,
      'Very low oxygen reading',
      'SpO2 ${o2?.round()}%. ${SafetyGuidance.action(RiskLevel.critical, ['critical_spo2'])}',
      critical: true,
      delay: Duration.zero,
    );
    condition(
      'fall',
      safety.fallState == FallWorkflowState.checkIn,
      'Possible fall — are you okay?',
      'Open SwasthyaShield to confirm you are okay. Ask someone nearby for help if needed.',
      critical: true,
      delay: Duration.zero,
    );
    condition(
      'fall_no_response',
      safety.fallState == FallWorkflowState.escalated,
      'Fall check-in unanswered',
      SafetyGuidance.action(RiskLevel.critical, ['fall_no_response']),
      critical: true,
      delay: Duration.zero,
    );
    condition(
      'connection',
      !fresh,
      'Wearable readings stopped',
      'Monitoring is waiting for fresh readings. Check Bluetooth, wearable power, and range.',
      delay: const Duration(seconds: 15),
    );
    condition(
      'signal',
      fresh && !safety.sensorTrust.canUsePhysiology,
      'Check sensor contact',
      'Pulse readings are unreliable. Adjust finger contact and hold still.',
      delay: const Duration(seconds: 45),
    );
    final independentCritical =
        safety.riskLevel == RiskLevel.critical &&
        !safety.fallDetected &&
        !(trust && o2 != null && o2 <= 88);
    condition(
      'risk_critical',
      fresh && independentCritical,
      'Urgent monitoring alert',
      SafetyGuidance.action(RiskLevel.critical, safety.reasons),
      critical: true,
      delay: Duration.zero,
    );
    condition(
      'risk_warning',
      fresh && safety.riskLevel == RiskLevel.warning,
      'Unusual readings need attention',
      SafetyGuidance.action(RiskLevel.warning, safety.reasons),
    );
    _since.removeWhere((key, _) => !active.contains(key));
    return alerts;
  }
}
