/// Transport contract for emergency SMS.
///
/// Kept abstract for the same reason as `TelemetrySource`: the escalation
/// logic is unit-testable without a radio, a SIM, or a real recipient.
abstract interface class SmsGateway {
  Future<bool> hasPermission();

  Future<bool> requestPermission();

  /// Hands the message to the cellular radio.
  ///
  /// Completing normally means the message was accepted for transmission, not
  /// that it reached the recipient. Throws [SmsSendException] on failure.
  Future<void> send({required String phone, required String message});

  /// Opens the platform SMS app with the alert prefilled. Requires a human
  /// tap, so it cannot serve an unconscious wearer.
  Future<void> openComposer({required String phone, required String message});
}

class SmsSendException implements Exception {
  const SmsSendException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'SmsSendException($code): $message';
}
