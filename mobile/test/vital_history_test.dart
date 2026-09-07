import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/vital_history.dart';

void main() {
  DateTime at(int second) => DateTime.utc(2026, 1, 1, 0, 0, second);

  test('keeps only the most recent samples', () {
    final history = VitalHistory(capacity: 5);
    for (var i = 0; i < 12; i++) {
      history.add(at: at(i), bpm: 60 + i.toDouble());
    }
    expect(history.samples.length, 5);
    expect(history.samples.first.bpm, 67);
    expect(history.latest, 71);
  });

  test('records an untrusted reading as a gap rather than dropping it', () {
    // When the sensor lost its grip is information the chart should show. If
    // gaps were simply not recorded, the trend would close over the dropout
    // and read as continuous monitoring through a period the device knew
    // nothing about.
    final history = VitalHistory();
    history.add(at: at(0), bpm: 70);
    history.add(at: at(1), bpm: null);
    history.add(at: at(2), bpm: 74);

    expect(history.samples.length, 3);
    expect(history.samples[1].hasValue, isFalse);
    expect(history.valued.length, 2);
  });

  test('range ignores gaps', () {
    final history = VitalHistory();
    history.add(at: at(0), bpm: 70);
    history.add(at: at(1), bpm: null);
    history.add(at: at(2), bpm: 90);

    expect(history.minimum, 70);
    expect(history.maximum, 90);
  });

  test('a history of nothing but gaps has no trend and no range', () {
    final history = VitalHistory();
    for (var i = 0; i < 10; i++) {
      history.add(at: at(i), bpm: null);
    }
    expect(history.isEmpty, isFalse);
    expect(history.hasTrend, isFalse);
    expect(history.minimum, isNull);
    expect(history.maximum, isNull);
  });

  test('needs two real readings before it claims a trend', () {
    final history = VitalHistory();
    expect(history.hasTrend, isFalse);
    history.add(at: at(0), bpm: 70);
    expect(history.hasTrend, isFalse, reason: 'one point is not a trend');
    history.add(at: at(1), bpm: 72);
    expect(history.hasTrend, isTrue);
  });
}
