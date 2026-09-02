import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/escalation/emergency_contact.dart';
import 'package:swasthyashield_edge/core/escalation/escalation_service.dart';
import 'package:swasthyashield_edge/core/escalation/sms_gateway.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';

class _FakeGateway implements SmsGateway {
  _FakeGateway({this.permitted = true, this.failWith});

  bool permitted;
  SmsSendException? failWith;

  final List<({String phone, String message})> sent = [];
  int permissionRequests = 0;
  int composerOpens = 0;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permitted;
  }

  @override
  Future<void> send({required String phone, required String message}) async {
    final failure = failWith;
    if (failure != null) throw failure;
    sent.add((phone: phone, message: message));
  }

  @override
  Future<void> openComposer({
    required String phone,
    required String message,
  }) async {
    composerOpens++;
  }
}

const _amma = EmergencyContact(id: 'c1', name: 'Amma', phone: '+919000000001');
const _bhai = EmergencyContact(id: 'c2', name: 'Bhai', phone: '+919000000002');

TelemetryFrame _frame() => TelemetryParser.tryParseMap(
  {'ts': 1788249600, 'q': 88, 'hr': 118.4, 'spo2': 91, 'at': 41.2, 'rh': 76},
  sourceType: TelemetrySourceType.ble,
  connectivity: TelemetryConnectivity.connected,
)!;

void main() {
  group('message composition', () {
    test('carries the reason and the vitals that justify it', () {
      final service = EscalationService(gateway: _FakeGateway());

      final message = service.composeMessage(
        reason: 'Heat stress',
        frame: _frame(),
        at: DateTime(2026, 9, 2, 14, 5),
      );

      expect(message, contains('Heat stress'));
      expect(message, contains('HR 118bpm'));
      expect(message, contains('SpO2 91%'));
      expect(message, contains('41.2C'));
      expect(message, contains('02/09 14:05'));
      expect(message, contains('do not reply'));
      // Ambient air, never a body-temperature claim.
      expect(message.toLowerCase(), isNot(contains('body')));
    });

    test('unavailable sensors show as dashes, never invented numbers', () {
      final service = EscalationService(gateway: _FakeGateway());
      final sparse = TelemetryParser.tryParseMap(
        {'ts': 1788249600, 'q': 40, 'hr': null, 'spo2': null},
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      )!;

      final message = service.composeMessage(reason: 'Fall', frame: sparse);

      expect(message, contains('HR --bpm'));
      expect(message, contains('SpO2 --%'));
    });

    test('stays within two SMS parts for a typical alert', () {
      final service = EscalationService(gateway: _FakeGateway());
      final message = service.composeMessage(
        reason: 'Fall detected, no response',
        frame: _frame(),
        at: DateTime(2026, 9, 2, 14, 5),
      );
      expect(message.length, lessThan(320));
    });
  });

  group('dispatch', () {
    test('sends to every configured contact', () async {
      final gateway = _FakeGateway();
      final service = EscalationService(gateway: gateway)
        ..loadContacts([_amma, _bhai]);

      final report = await service.escalate(reason: 'Fall', frame: _frame());

      expect(gateway.sent.length, 2);
      expect(
        gateway.sent.map((e) => e.phone),
        containsAll([_amma.phone, _bhai.phone]),
      );
      expect(report.anyDispatched, isTrue);
      expect(
        report.results.every((r) => r.outcome == EscalationOutcome.sent),
        isTrue,
      );
    });

    test(
      'with no contacts configured nothing is sent and the report says so',
      () async {
        final gateway = _FakeGateway();
        final service = EscalationService(gateway: gateway);

        final report = await service.escalate(reason: 'Fall');

        expect(gateway.sent, isEmpty);
        expect(report.hadContacts, isFalse);
        expect(report.anyDispatched, isFalse);
      },
    );

    test('rehearsal mode composes but never reaches the radio', () async {
      final gateway = _FakeGateway();
      final service = EscalationService(gateway: gateway, dryRun: true)
        ..loadContacts([_amma]);

      final report = await service.escalate(reason: 'Fall', frame: _frame());

      expect(gateway.sent, isEmpty);
      expect(
        gateway.permissionRequests,
        0,
        reason: 'a rehearsal must not prompt for a real permission',
      );
      expect(report.results.single.outcome, EscalationOutcome.simulated);
      expect(report.anyDispatched, isTrue);
    });

    test(
      'a denied permission is reported per contact, not half-sent',
      () async {
        final gateway = _FakeGateway(permitted: false);
        final service = EscalationService(gateway: gateway)
          ..loadContacts([_amma, _bhai]);

        final report = await service.escalate(reason: 'Fall');

        expect(gateway.sent, isEmpty);
        expect(
          report.results.every(
            (r) => r.outcome == EscalationOutcome.permissionDenied,
          ),
          isTrue,
        );
        expect(report.results.first.note, contains('permission'));
        expect(report.anyDispatched, isFalse);
      },
    );

    test('a radio failure is surfaced with its reason', () async {
      final gateway = _FakeGateway(
        failWith: const SmsSendException('no_service', 'No cellular service'),
      );
      final service = EscalationService(gateway: gateway)
        ..loadContacts([_amma]);

      final report = await service.escalate(reason: 'Fall');

      expect(report.results.single.outcome, EscalationOutcome.failed);
      expect(report.results.single.note, contains('No cellular service'));
      expect(report.anyDispatched, isFalse);
    });
  });

  group('cooldown', () {
    test('a repeat inside the window is held, and says why', () async {
      final gateway = _FakeGateway();
      final service = EscalationService(
        gateway: gateway,
        cooldown: const Duration(minutes: 5),
      )..loadContacts([_amma]);

      final start = DateTime(2026, 9, 2, 14, 0);
      await service.escalate(reason: 'Fall', now: start);
      final second = await service.escalate(
        reason: 'Fall',
        now: start.add(const Duration(minutes: 1)),
      );

      expect(gateway.sent.length, 1, reason: 'the second send is suppressed');
      expect(second.results.single.outcome, EscalationOutcome.heldByCooldown);
      // A held alert must never look like a silent failure.
      expect(second.results.single.note, contains('Retries in'));
    });

    test('sends again once the window has passed', () async {
      final gateway = _FakeGateway();
      final service = EscalationService(
        gateway: gateway,
        cooldown: const Duration(minutes: 5),
      )..loadContacts([_amma]);

      final start = DateTime(2026, 9, 2, 14, 0);
      await service.escalate(reason: 'Fall', now: start);
      await service.escalate(
        reason: 'Fall',
        now: start.add(const Duration(minutes: 6)),
      );

      expect(gateway.sent.length, 2);
    });

    test(
      'is per contact, so a new contact is not blocked by an old send',
      () async {
        final gateway = _FakeGateway();
        final service = EscalationService(gateway: gateway)
          ..loadContacts([_amma]);

        final start = DateTime(2026, 9, 2, 14, 0);
        await service.escalate(reason: 'Fall', now: start);
        service.addContact(_bhai);
        final second = await service.escalate(
          reason: 'Fall',
          now: start.add(const Duration(minutes: 1)),
        );

        final byId = {for (final r in second.results) r.contact.id: r.outcome};
        expect(byId[_amma.id], EscalationOutcome.heldByCooldown);
        expect(byId[_bhai.id], EscalationOutcome.sent);
      },
    );

    test(
      'resetting cooldowns lets a rehearsal be repeated immediately',
      () async {
        final gateway = _FakeGateway();
        final service = EscalationService(gateway: gateway)
          ..loadContacts([_amma]);

        final start = DateTime(2026, 9, 2, 14, 0);
        await service.escalate(reason: 'Fall', now: start);
        service.resetCooldowns();
        final second = await service.escalate(
          reason: 'Fall',
          now: start.add(const Duration(seconds: 5)),
        );

        expect(second.results.single.outcome, EscalationOutcome.sent);
        expect(gateway.sent.length, 2);
      },
    );
  });

  group('contacts', () {
    test('accepts realistic numbers and rejects junk', () {
      expect(EmergencyContact.isValidPhone('+91 90000 00001'), isTrue);
      expect(EmergencyContact.isValidPhone('9000000001'), isTrue);
      expect(EmergencyContact.isValidPhone('+91-90000-00001'), isTrue);
      expect(EmergencyContact.isValidPhone('12345'), isFalse);
      expect(EmergencyContact.isValidPhone('not a number'), isFalse);
      expect(EmergencyContact.isValidPhone(''), isFalse);
    });

    test('survives a round trip through storage json', () {
      final restored = EmergencyContact.fromJson(_amma.toJson());
      expect(restored, _amma);
    });

    test('a corrupt stored entry is dropped, not crashed on', () {
      expect(EmergencyContact.fromJson({'id': 'x'}), isNull);
      expect(
        EmergencyContact.fromJson({'id': '', 'name': 'a', 'phone': '1'}),
        isNull,
      );
    });

    test('removing a contact clears its cooldown too', () async {
      final gateway = _FakeGateway();
      final service = EscalationService(gateway: gateway)
        ..loadContacts([_amma]);

      final start = DateTime(2026, 9, 2, 14, 0);
      await service.escalate(reason: 'Fall', now: start);
      expect(service.cooldownRemaining(_amma.id, now: start), isNotNull);

      service.removeContact(_amma.id);

      expect(service.cooldownRemaining(_amma.id, now: start), isNull);
    });
  });
}
