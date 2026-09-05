import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// On-device autoencoder inference.
///
/// This is a line-for-line port of `backend/src/ml/anomalyModel.js`. The model
/// is a 4-layer MLP of roughly 4k parameters, so the forward pass is plain
/// arithmetic — no plugin, no native library, no download. It runs entirely on
/// the phone, which is what lets the companion keep scoring vitals with the
/// network off and without a reading ever leaving the device.
///
/// The score is reconstruction error. The autoencoder was trained only on
/// healthy physiology, so a window it cannot reproduce is unlike anything it
/// was shown. A high score means "this does not look like normal" — it is NOT
/// a diagnosis. The model has no labels for named conditions and cannot
/// identify one.
///
/// Weights come from `ml/export_weights.py` via `assets/ml/model.json`. That
/// file is generated; do not hand-edit it.
class AnomalyModel {
  AnomalyModel._({
    required this.features,
    required this.window,
    required this.threshold,
    required List<double> mean,
    required List<double> std,
    required List<_Layer> layers,
  }) : _mean = mean,
       _std = std,
       _layers = layers;

  /// Feature names, in the order the network expects them.
  final List<String> features;

  /// Number of samples the model scores at once.
  final int window;

  /// Reconstruction error at or above which a window is called anomalous.
  final double threshold;

  final List<double> _mean;
  final List<double> _std;
  final List<_Layer> _layers;

  static const String assetPath = 'assets/ml/model.json';

  /// Loads and compiles the model from the bundled asset.
  ///
  /// Returns null when the asset is missing or malformed. The model is
  /// deliberately optional: the rule engine is the floor and must keep working
  /// on its own, so a failure here degrades to "no opinion" rather than
  /// breaking monitoring.
  static Future<AnomalyModel?> load() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// Builds a model from an already-decoded spec. Exposed for tests.
  static AnomalyModel? fromJson(Map<String, dynamic> spec) {
    try {
      final features = (spec['features'] as List).cast<String>();
      final window = (spec['window'] as num).toInt();
      final normalisation = spec['normalisation'] as Map<String, dynamic>;
      final mean = (normalisation['mean'] as List)
          .map((v) => (v as num).toDouble())
          .toList();
      final std = (normalisation['std'] as List)
          .map((v) => (v as num).toDouble())
          .toList();
      final activations = (spec['activations'] as List).cast<String>();

      final layers = <_Layer>[];
      final rawLayers = spec['layers'] as List;
      for (var i = 0; i < rawLayers.length; i++) {
        final l = rawLayers[i] as Map<String, dynamic>;
        layers.add(
          _Layer(
            inDim: (l['in'] as num).toInt(),
            outDim: (l['out'] as num).toInt(),
            weights: Float32List.fromList(
              (l['W'] as List).map((v) => (v as num).toDouble()).toList(),
            ),
            bias: Float32List.fromList(
              (l['b'] as List).map((v) => (v as num).toDouble()).toList(),
            ),
            relu: activations[i] == 'relu',
          ),
        );
      }

      // A mismatch here means the asset and this code disagree about shape,
      // which would otherwise surface as silently meaningless scores.
      if (layers.isEmpty || layers.first.inDim != window * features.length) {
        return null;
      }

      return AnomalyModel._(
        features: features,
        window: window,
        threshold: (spec['threshold'] as num).toDouble(),
        mean: mean,
        std: std,
        layers: layers,
      );
    } on Object {
      return null;
    }
  }

  /// Scores one window, oldest sample first.
  ///
  /// Returns null when the window is short or a required vital is missing —
  /// the model gives no opinion rather than an invented one.
  AnomalyScore? score(List<Map<String, double?>> samples) {
    if (samples.length < window) return null;

    final recent = _smooth(samples.sublist(samples.length - window));
    if (recent == null) return null;

    final n = window * features.length;
    final x = Float32List(n);
    var k = 0;
    for (var t = 0; t < window; t++) {
      for (var f = 0; f < features.length; f++) {
        final v = recent[t][features[f]];
        if (v == null || v.isNaN) return null;
        // Same flattening order as training: time-major, features interleaved.
        final s = _std[f] == 0 ? 1e-6 : _std[f];
        x[k++] = (v - _mean[f]) / s;
      }
    }

    final out = _forward(x);

    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final d = out[i] - x[i];
      sum += d * d;
    }
    final error = sum / n;

    return AnomalyScore(
      score: error,
      anomalous: error >= threshold,
      ratio: error / threshold,
    );
  }

  /// y = ReLU?(W x + b), with W stored row-major as (out, in).
  Float32List _forward(Float32List input) {
    var h = input;
    for (final layer in _layers) {
      final out = Float32List(layer.outDim);
      for (var o = 0; o < layer.outDim; o++) {
        var sum = layer.bias[o];
        final row = o * layer.inDim;
        for (var i = 0; i < layer.inDim; i++) {
          sum += layer.weights[row + i] * h[i];
        }
        out[o] = layer.relu ? math.max(0.0, sum) : sum;
      }
      h = out;
    }
    return h;
  }

  /// Width-5 centred median filter, applied before normalisation.
  ///
  /// Must stay identical to `smooth()` in anomalyModel.js and `median5()` in
  /// ml/prepare_data.py.
  ///
  /// The model was trained on BIDMC numerics, where SpO2 holds steady between
  /// 95.7% of consecutive samples and HR between 72.2% — it effectively learned
  /// that these vitals do not move inside a 30 second window. A MAX30102 emits
  /// integers that flicker by a count constantly, and a bottlenecked
  /// autoencoder cannot reproduce that jitter, so without this filter the
  /// reconstruction error measures sensor noise instead of physiology. Measured
  /// on windows that were all physiologically normal, a one-count SpO2 flicker
  /// alone pushed 93% of them past the anomaly threshold.
  ///
  /// A median is the right filter here: it removes single-sample spikes
  /// outright while leaving a genuine step edge intact, so a real desaturation
  /// still arrives at full amplitude.
  List<Map<String, double?>>? _smooth(List<Map<String, double?>> win) {
    final n = win.length;
    if (n == 0) return null;
    const half = 2;
    final out = <Map<String, double?>>[];
    final scratch = List<double>.filled(2 * half + 1, 0);

    for (var i = 0; i < n; i++) {
      final sample = <String, double?>{};
      for (final f in features) {
        var m = 0;
        for (var j = -half; j <= half; j++) {
          final idx = math.min(n - 1, math.max(0, i + j));
          final v = win[idx][f];
          if (v == null || v.isNaN) return null;
          scratch[m++] = v;
        }
        scratch.sort();
        sample[f] = scratch[half];
      }
      out.add(sample);
    }
    return out;
  }
}

/// One layer's compiled weights.
class _Layer {
  const _Layer({
    required this.inDim,
    required this.outDim,
    required this.weights,
    required this.bias,
    required this.relu,
  });

  final int inDim;
  final int outDim;
  final Float32List weights;
  final Float32List bias;
  final bool relu;
}

/// The model's opinion on one window.
class AnomalyScore {
  const AnomalyScore({
    required this.score,
    required this.anomalous,
    required this.ratio,
  });

  /// Mean squared reconstruction error.
  final double score;

  /// True when [score] is at or above the model's threshold.
  final bool anomalous;

  /// How far past the threshold, for display. 1.0 is exactly at it.
  final double ratio;
}
