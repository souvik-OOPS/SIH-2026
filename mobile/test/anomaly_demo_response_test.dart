import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/ml/anomaly_detector.dart';
import 'package:swasthyashield_edge/core/ml/anomaly_model.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_source.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';

/// Runs the bundled demo scenarios through the on-device model and records how
/// it responds, so the behaviour shown on the phone is reproducible here.
///
/// The demo fixtures are 6-10 frames and the model scores a 30-sample window,
/// so the replay source loops them. That is faithful to the app: the card
/// shows "Gathering baseline" until roughly 30 seconds of contact have
/// accumulated, then scores every frame after.
void main() {
  late AnomalyModel model;

  setUpAll(() {
    final raw = File('assets/ml/model.json').readAsStringSync();
    model = AnomalyModel.fromJson(jsonDecode(raw) as Map<String, dynamic>)!;
  });

  /// Replays one fixture, looping as the app does, and returns each score.
  List<AnomalyScore> replay(String scenario, {int frames = 90}) {
    final raw = File('assets/demo/$scenario.json').readAsStringSync();
    final fixture = jsonDecode(raw) as Map<String, dynamic>;
    final rows = (fixture['frames'] as List).cast<Map<String, dynamic>>();

    final detector = AnomalyDetector.withModel(model);
    final scores = <AnomalyScore>[];

    for (var i = 0; i < frames; i++) {
      final parsed = TelemetryParser.tryParseMap(
        Map<String, dynamic>.from(rows[i % rows.length]),
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );
      if (parsed == null) continue;
      final score = detector.accept(parsed);
      if (score != null) scores.add(score);
    }
    return scores;
  }

  void report(String scenario, List<AnomalyScore> scores) {
    if (scores.isEmpty) {
      // ignore: avoid_print
      print('  $scenario: no scores produced');
      return;
    }
    final ratios = scores.map((s) => s.ratio).toList()..sort();
    final flagged = scores.where((s) => s.ratio >= 1.6).length;
    // ignore: avoid_print
    print(
      '  ${scenario.padRight(17)} scored ${scores.length.toString().padLeft(3)}   '
      'ratio min ${ratios.first.toStringAsFixed(2).padLeft(6)}  '
      'median ${ratios[ratios.length ~/ 2].toStringAsFixed(2).padLeft(6)}  '
      'max ${ratios.last.toStringAsFixed(2).padLeft(7)}   '
      'past 1.6x: $flagged/${scores.length}',
    );
  }

  test('demo scenarios: how the on-device model responds', () {
    // ignore: avoid_print
    print('\nOn-device model response to the bundled demo fixtures:');
    for (final scenario in ['normal', 'heat_warning', 'fall_nonresponse', 'bad_signal']) {
      report(scenario, replay(scenario));
    }
    // ignore: avoid_print
    print('');
  });

  test('a resting demo wearer is not called anomalous', () {
    final scores = replay('normal');
    expect(scores, isNotEmpty, reason: 'the looped fixture should fill the window');

    final flagged = scores.where((s) => s.ratio >= 1.6).length;
    expect(
      flagged,
      0,
      reason: 'HR 71-73 with SpO2 98-99 is healthy; flagging it would be a false alarm',
    );
  });

  test('rising strain scores higher than rest', () {
    final rest = replay('normal');
    final heat = replay('heat_warning');
    expect(rest, isNotEmpty);
    expect(heat, isNotEmpty);

    double median(List<AnomalyScore> s) {
      final r = s.map((e) => e.ratio).toList()..sort();
      return r[r.length ~/ 2];
    }

    // The heat fixture climbs to HR 112 with SpO2 falling to 95. The model was
    // trained on resting physiology, so it should find that less familiar than
    // a resting wearer - this is the ordering the card depends on.
    expect(
      median(heat),
      greaterThan(median(rest)),
      reason: 'exertion under heat must score further from normal than rest',
    );
  });

  test('untrustworthy sensor data is never scored', () {
    // Regression. The bad_signal fixture reports finger contact while carrying
    // 7-38% confidence and HR stepping 74 -> 126 -> 49 -> 151 between seconds.
    // Scored raw it came out at 190x the anomaly threshold - louder than any
    // real emergency in these fixtures, from a wearer who is fine. A sensor
    // losing its grip must not be able to out-shout a genuine event.
    final scores = replay('bad_signal');
    expect(
      scores,
      isEmpty,
      reason: 'a sensor that cannot be trusted must produce no opinion at all',
    );
  });

  test('a frame with no finger contact is never scored', () {
    // Feeding the model data the app itself distrusts would manufacture
    // anomalies out of the finger simply lifting off the sensor.
    final detector = AnomalyDetector.withModel(model);
    for (var i = 0; i < 60; i++) {
      final frame = TelemetryParser.tryParseMap(
        {'ts': 1788249600 + i, 'hr': 72, 'spo2': 98, 'q': 10, 'contact': 'no_finger'},
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );
      expect(detector.accept(frame!), isNull);
    }
    expect(detector.samples, 0);
  });
}
