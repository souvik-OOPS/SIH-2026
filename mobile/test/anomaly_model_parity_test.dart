import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/ml/anomaly_model.dart';

/// Proves the Dart forward pass agrees with the JavaScript one.
///
/// The same weights run in three places now — numpy in training,
/// backend/src/ml/anomalyModel.js on the server, and Dart on the phone. Three
/// hand-written implementations of the same arithmetic is exactly the setup
/// where one silently drifts: a transposed weight matrix or a different
/// flatten order still produces plausible-looking numbers, and nobody notices
/// until the phone and the server disagree about whether someone is in danger.
///
/// The expected values below were produced by running the JS implementation
/// against this same model.json and window (ml/test_inference_parity.py holds
/// the JS-versus-numpy half of the same chain).
void main() {
  late AnomalyModel model;

  setUpAll(() {
    // Read the asset straight off disk. rootBundle needs a full Flutter
    // binding, and this test is about arithmetic, not asset plumbing.
    final raw = File('assets/ml/model.json').readAsStringSync();
    final built = AnomalyModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    expect(built, isNotNull, reason: 'assets/ml/model.json failed to parse');
    model = built!;
  });

  test('model metadata matches the exported weights', () {
    expect(model.features, ['HR', 'SpO2']);
    expect(model.window, 30);
    expect(model.threshold, closeTo(0.026883819510514072, 1e-15));
  });

  test('scores a normal window identically to the JS implementation', () {
    final window = List.generate(model.window, (t) {
      return <String, double?>{
        'HR': 80 + 5 * math.sin(t / 3.0),
        'SpO2': 97 + 0.5 * math.cos(t / 4.0),
      };
    });

    final result = model.score(window);
    expect(result, isNotNull);
    // JS: 0.001273283512
    expect(result!.score, closeTo(0.001273283512, 1e-9));
    expect(result.ratio, closeTo(0.047362448, 1e-6));
    expect(result.anomalous, isFalse);
  });

  test('scores a hypoxic window identically to the JS implementation', () {
    final window = List.generate(model.window, (t) {
      return <String, double?>{
        'HR': 138 + (t % 3).toDouble(),
        'SpO2': 81 + (t % 2).toDouble(),
      };
    });

    final result = model.score(window);
    expect(result, isNotNull);
    // JS: 0.229636610333
    expect(result!.score, closeTo(0.229636610333, 1e-9));
    expect(result.ratio, closeTo(8.541814910, 1e-6));
    expect(result.anomalous, isTrue);
  });

  test('the median filter suppresses one-count sensor flicker', () {
    // The fault this filter exists for: SpO2 alternating by a single count is
    // ordinary sensor behaviour, and without smoothing it drove 93% of
    // physiologically normal windows past the anomaly threshold.
    final flickering = List.generate(model.window, (t) {
      return <String, double?>{'HR': 73 + (t % 2).toDouble(), 'SpO2': 97 + (t % 2).toDouble()};
    });

    final result = model.score(flickering);
    expect(result, isNotNull);
    expect(
      result!.anomalous,
      isFalse,
      reason: 'a one-count flicker on healthy vitals must not read as anomalous',
    );
  });

  test('gives no opinion rather than a guess on unusable input', () {
    expect(model.score([]), isNull);

    final short = List.generate(model.window - 1, (_) {
      return <String, double?>{'HR': 72.0, 'SpO2': 98.0};
    });
    expect(model.score(short), isNull, reason: 'a partial window must score null');

    final missing = List.generate(model.window, (t) {
      return <String, double?>{'HR': t == 5 ? null : 72.0, 'SpO2': 98.0};
    });
    expect(model.score(missing), isNull, reason: 'a missing vital must score null');
  });
}
