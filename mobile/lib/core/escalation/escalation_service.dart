import 'package:flutter/foundation.dart';

import '../models/telemetry_frame.dart';
import 'emergency_contact.dart';
import 'sms_gateway.dart';

enum EscalationOutcome {
  sent,
  simulated,
  heldByCooldown,
  permissionDenied,
  failed,
}

/// What happened for one contact, and why.
///
/// A suppressed message always carries its reason: the project's rule is that
/// a held alert must never look like a silent failure.
class ContactEscalationResult {
  const ContactEscalationResult({
    required this.contact,
    required this.outcome,
    required this.note,
  });

  final EmergencyContact contact;
  final EscalationOutcome outcome;
  final String note;
}

class EscalationReport {
  const EscalationReport({
    required this.at,
    required this.reason,
    required this.message,
    required this.results,
  });

  final DateTime at;
  final String reason;
  final String message;
  final List<ContactEscalationResult> results;

  bool get anyDispatched => results.any(
    (result) =>
        result.outcome == EscalationOutcome.sent ||
        result.outcome == EscalationOutcome.simulated,
  );

  bool get hadContacts => results.isNotEmpty;
}

/// Sends emergency SMS straight from the phone.
///
/// SMS rides the cellular control channel, so it survives the loss of mobile
/// data and Wi-Fi. That removes the backend from the critical alert path
/// entirely, which is the point: in a disaster the server may be unreachable
/// exactly when escalation matters most.
class EscalationService extends ChangeNotifier {
  EscalationService({
    required SmsGateway gateway,
    this.cooldown = const Duration(minutes: 5),
    bool dryRun = false,
  }) : _gateway = gateway,
       _dryRun = dryRun;

  final SmsGateway _gateway;

  /// Mirrors the backend's SMS_COOLDOWN_MS so both escalation paths behave
  /// alike and a re-run demo does not spam a real phone.
  final Duration cooldown;

  final Map<String, DateTime> _lastSentAt = {};
  List<EmergencyContact> _contacts = const [];
  EscalationReport? _lastReport;
  bool _dryRun;

  List<EmergencyContact> get contacts => List.unmodifiable(_contacts);
  EscalationReport? get lastReport => _lastReport;

  /// Rehearsal mode: compose and report, but never hand anything to the radio.
  bool get dryRun => _dryRun;
  set dryRun(bool value) {
    if (_dryRun == value) return;
    _dryRun = value;
    notifyListeners();
  }

  void loadContacts(List<EmergencyContact> contacts) {
    _contacts = List.of(contacts);
    notifyListeners();
  }

  void addContact(EmergencyContact contact) {
    _contacts = [..._contacts, contact];
    notifyListeners();
  }

  void removeContact(String id) {
    _contacts = _contacts.where((contact) => contact.id != id).toList();
    _lastSentAt.remove(id);
    notifyListeners();
  }

  /// Clears the per-contact cooldowns. Used by the demo reset, so a rehearsal
  /// can be repeated without waiting out the window.
  void resetCooldowns() {
    _lastSentAt.clear();
    notifyListeners();
  }

  Duration? cooldownRemaining(String contactId, {DateTime? now}) {
    final last = _lastSentAt[contactId];
    if (last == null) return null;
    final elapsed = (now ?? DateTime.now()).difference(last);
    if (elapsed >= cooldown) return null;
    return cooldown - elapsed;
  }

  Future<EscalationReport> escalate({
    required String reason,
    TelemetryFrame? frame,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final message = composeMessage(reason: reason, frame: frame, at: at);

    if (_contacts.isEmpty) {
      final report = EscalationReport(
        at: at,
        reason: reason,
        message: message,
        results: const [],
      );
      _lastReport = report;
      notifyListeners();
      return report;
    }

    // Permission is checked once per escalation, not per contact, so a denied
    // permission reports the same way for everyone rather than half-sending.
    var permitted = true;
    if (!_dryRun) {
      permitted = await _gateway.hasPermission();
      if (!permitted) permitted = await _gateway.requestPermission();
    }

    final results = <ContactEscalationResult>[];
    for (final contact in _contacts) {
      final remaining = cooldownRemaining(contact.id, now: at);
      if (remaining != null) {
        results.add(
          ContactEscalationResult(
            contact: contact,
            outcome: EscalationOutcome.heldByCooldown,
            note:
                'Held: another alert went out '
                '${(cooldown - remaining).inSeconds}s ago. '
                'Retries in ${remaining.inSeconds}s.',
          ),
        );
        continue;
      }

      if (_dryRun) {
        _lastSentAt[contact.id] = at;
        results.add(
          ContactEscalationResult(
            contact: contact,
            outcome: EscalationOutcome.simulated,
            note: 'Rehearsal mode: composed but not transmitted.',
          ),
        );
        continue;
      }

      if (!permitted) {
        results.add(
          ContactEscalationResult(
            contact: contact,
            outcome: EscalationOutcome.permissionDenied,
            note: 'SMS permission was denied, so nothing was sent.',
          ),
        );
        continue;
      }

      try {
        await _gateway.send(phone: contact.phone, message: message);
        _lastSentAt[contact.id] = at;
        results.add(
          ContactEscalationResult(
            contact: contact,
            outcome: EscalationOutcome.sent,
            note: 'Handed to the cellular radio. Delivery is not confirmed.',
          ),
        );
      } on SmsSendException catch (error) {
        results.add(
          ContactEscalationResult(
            contact: contact,
            outcome: EscalationOutcome.failed,
            note: 'Send failed (${error.code}): ${error.message}',
          ),
        );
      } on Object catch (error) {
        results.add(
          ContactEscalationResult(
            contact: contact,
            outcome: EscalationOutcome.failed,
            note: 'Send failed: $error',
          ),
        );
      }
    }

    final report = EscalationReport(
      at: at,
      reason: reason,
      message: message,
      results: results,
    );
    _lastReport = report;
    notifyListeners();
    return report;
  }

  /// Kept short on purpose: every 160 characters is another billed SMS part,
  /// and a long alert is slower to read at the worst possible moment.
  String composeMessage({
    required String reason,
    TelemetryFrame? frame,
    DateTime? at,
  }) {
    final stamp = at ?? DateTime.now();
    final buffer = StringBuffer('SwasthyaShield alert: $reason');

    if (frame != null) {
      final hr = frame.heartRateBpm?.toStringAsFixed(0) ?? '--';
      final spo2 = frame.spo2Percent?.toStringAsFixed(0) ?? '--';
      buffer.write('\nHR ${hr}bpm SpO2 $spo2%');

      final temperature = frame.ambientTemperatureC?.toStringAsFixed(1);
      final humidity = frame.humidityPercent?.toStringAsFixed(0);
      if (temperature != null || humidity != null) {
        // Ambient, never body temperature - the DHT22 measures the air.
        buffer.write('\nAir ${temperature ?? '--'}C ${humidity ?? '--'}%RH');
      }
    }

    buffer.write('\n${_stampLabel(stamp)}');
    buffer.write('\nAutomated alert, do not reply.');
    return buffer.toString();
  }

  static String _stampLabel(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
