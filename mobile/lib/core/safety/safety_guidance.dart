import '../../assistant/models/assistant_context.dart';

/// Shared prototype wording. Generated text never replaces urgent instructions.
abstract final class SafetyGuidance {
  static String action(
    RiskLevel level,
    List<String> reasons, {
    bool hindi = false,
  }) {
    if (level == RiskLevel.critical) {
      return hindi
          ? 'तुरंत मदद लें। किसी पास के व्यक्ति को बुलाएँ। व्यक्ति बेहोश हो या साँस लेने में गंभीर परेशानी हो तो 112 पर कॉल करें। चैट के उत्तर का इंतज़ार न करें।'
          : 'Get help now. Alert someone nearby. If the person is unresponsive or has severe difficulty breathing, call 112. Do not wait for a chat response.';
    }
    if (reasons.any((r) => r.contains('fall'))) {
      return hindi
          ? 'व्यक्ति को तुरंत देखें और ऐप में पुष्टि करें कि वे ठीक हैं।'
          : 'Check on the person now and confirm in the app if they are okay.';
    }
    if (reasons.any((r) => r.contains('heat'))) {
      return hindi
          ? 'मेहनत रोकें और ठंडी या छायादार जगह जाएँ। परेशानी बनी रहे तो मदद लें।'
          : 'Stop exertion and move to a cooler or shaded place. Seek help if you continue to feel unwell.';
    }
    if (level == RiskLevel.warning || level == RiskLevel.watch) {
      return hindi
          ? 'आराम करें, सेंसर संपर्क जाँचें और रीडिंग दोबारा देखें। परेशानी या असामान्य रीडिंग बनी रहे तो मदद लें।'
          : 'Rest, check sensor contact, and recheck the readings. Seek help if symptoms or unusual readings persist.';
    }
    return hindi
        ? 'निगरानी जारी रखें। सामान्य रीडिंग किसी समस्या को पूरी तरह खारिज नहीं करती।'
        : 'Continue monitoring. Normal readings cannot rule out a health problem.';
  }
}
