import '../../core/safety/safety_guidance.dart';
import '../models/assistant_context.dart';
import '../models/assistant_request.dart';

/// Deterministic answers for current state and urgent situations, in every engine.
abstract final class AssistantResponsePolicy {
  static String? requiredAnswer(AssistantRequest request) {
    final c = request.context;
    if (c.riskLevel.isElevated || c.fallDetected || c.sosPressed) {
      return status(request);
    }
    final q = request.question.toLowerCase();
    // These intents describe the application, so an LLM must not invent them.
    if (RegExp(
      r'\b(warning|alert|current|condition|status|reliable|confidence|reading|safe|okay|ok)\b|what should|what now|risk|ठीक|चेतावनी|रीडिंग|स्थिति|भरोस|अब क्या|क्या कर',
    ).hasMatch(q)) {
      return status(request);
    }
    return null;
  }

  static String status(AssistantRequest request) {
    final c = request.context;
    final hi = request.language == AssistantLanguage.hindi;
    final parts = <String>[];
    if (c.riskLevel.isElevated || c.fallDetected || c.sosPressed) {
      parts.add(
        SafetyGuidance.action(
          c.sosPressed || c.fallDetected ? RiskLevel.critical : c.riskLevel,
          c.reasons,
          hindi: hi,
        ),
      );
    }
    if (!c.telemetryAvailable ||
        c.dataIsStale ||
        c.connectivity == 'disconnected') {
      parts.add(
        hi
            ? 'ताज़ा सेंसर डेटा उपलब्ध नहीं है। पहनने वाले उपकरण की पावर, दूरी और Bluetooth जाँचें। पुराने नंबर मौजूदा स्थिति नहीं बताते।'
            : 'Fresh sensor data is unavailable. Check wearable power, distance, and Bluetooth. Old readings do not describe your current condition.',
      );
    } else if (c.readingsUnreliable) {
      parts.add(
        hi
            ? 'पल्स सेंसर की रीडिंग अभी भरोसेमंद नहीं है। उंगली सेंसर पर रखें और स्थिर रहें।'
            : 'The pulse readings are unreliable right now. Adjust finger contact and hold still for a fresh measurement.',
      );
    } else {
      final readings = <String>[
        if (c.heartRate != null)
          '${hi ? 'हृदय गति' : 'Heart rate'} ${c.heartRate!.round()} bpm',
        if (c.spo2 != null) 'SpO2 ${c.spo2!.round()}%',
        if (c.ambientTemperature != null)
          '${hi ? 'हवा का तापमान' : 'air temperature'} ${c.ambientTemperature!.toStringAsFixed(1)} °C',
      ];
      if (readings.isNotEmpty) parts.add('${readings.join(', ')}.');
    }
    parts.add(
      c.riskLevel == RiskLevel.notComputed
          ? (hi
                ? 'जोखिम का आकलन अभी उपलब्ध नहीं है।'
                : 'A risk assessment is not available yet.')
          : '${hi ? 'ऐप का जोखिम स्तर' : 'App risk level'}: ${c.riskLevel.wireValue}.',
    );
    final reasons = c.reasons
        .where((r) => r != 'sensor_trust')
        .map((r) => _reason(r, hi))
        .toList();
    if (reasons.isNotEmpty) {
      parts.add(
        '${hi ? 'कारण' : 'Contributing factors'}: ${reasons.join('; ')}.',
      );
    }
    if (c.measuredAt != null) {
      final at = c.measuredAt!.toLocal();
      parts.add(
        '${hi ? 'आखिरी डेटा' : 'Last received'}: ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}.',
      );
    }
    if (c.riskLevel == RiskLevel.normal &&
        !c.sosPressed &&
        !c.fallDetected &&
        !c.readingsUnreliable &&
        c.telemetryAvailable) {
      parts.add(SafetyGuidance.action(c.riskLevel, c.reasons, hindi: hi));
    }
    if (c.sourceType == 'replay') {
      parts.add(hi ? 'यह डेमो डेटा है।' : 'These are demonstration readings.');
    }
    return parts.join('\n\n');
  }

  static String _reason(String reason, bool hi) => switch (reason) {
    'heat_exposure' => hi ? 'गर्म और नम वातावरण' : 'hot or humid surroundings',
    'heart_rate_deviation' =>
      hi
          ? 'व्यक्तिगत आधार से हृदय गति में बदलाव'
          : 'heart rate differs from your baseline',
    'spo2_deviation' ||
    'critical_spo2' => hi ? 'ऑक्सीजन रीडिंग कम है' : 'reduced oxygen reading',
    'activity_level' => hi ? 'शारीरिक गतिविधि' : 'physical activity',
    'persistence' => hi ? 'बदलाव बना हुआ है' : 'changes have persisted',
    'anomaly_score' =>
      hi ? 'असामान्य सेंसर पैटर्न' : 'an unusual sensor pattern',
    'fall_check_in' =>
      hi ? 'गिरने की आशंका, पुष्टि चाहिए' : 'possible fall awaiting check-in',
    'fall_no_response' =>
      hi
          ? 'गिरने के बाद उत्तर नहीं मिला'
          : 'fall check-in received no response',
    _ =>
      hi
          ? 'डैशबोर्ड पर अतिरिक्त कारण देखें'
          : 'see additional evidence on the dashboard',
  };
}
