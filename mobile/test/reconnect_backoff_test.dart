import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/telemetry/reconnect_backoff.dart';

void main() {
  group('ReconnectBackoff', () {
    test('doubles the delay for each failed attempt', () {
      final backoff = ReconnectBackoff(
        initial: const Duration(seconds: 4),
        max: const Duration(seconds: 60),
      );

      expect(backoff.next(), const Duration(seconds: 4));
      expect(backoff.next(), const Duration(seconds: 8));
      expect(backoff.next(), const Duration(seconds: 16));
      expect(backoff.next(), const Duration(seconds: 32));
    });

    test(
      'never scans more often than the cap allows, however long it fails',
      () {
        final backoff = ReconnectBackoff(
          initial: const Duration(seconds: 4),
          max: const Duration(seconds: 60),
        );

        for (var attempt = 0; attempt < 50; attempt++) {
          final delay = backoff.next();
          expect(delay, lessThanOrEqualTo(const Duration(seconds: 60)));
        }
        // A wearable left switched off must settle at the cap, not keep the
        // radio busy on a short fixed interval.
        expect(backoff.current, const Duration(seconds: 60));
      },
    );

    test('a successful connection restores prompt retries', () {
      final backoff = ReconnectBackoff(
        initial: const Duration(seconds: 4),
        max: const Duration(seconds: 60),
      );

      backoff.next();
      backoff.next();
      backoff.next();
      expect(backoff.current, greaterThan(const Duration(seconds: 4)));

      backoff.reset();

      expect(backoff.current, const Duration(seconds: 4));
      expect(backoff.next(), const Duration(seconds: 4));
    });

    test('a cap shorter than one doubling step is still respected', () {
      final backoff = ReconnectBackoff(
        initial: const Duration(seconds: 4),
        max: const Duration(seconds: 5),
      );

      expect(backoff.next(), const Duration(seconds: 4));
      expect(backoff.next(), const Duration(seconds: 5));
      expect(backoff.next(), const Duration(seconds: 5));
    });
  });
}
