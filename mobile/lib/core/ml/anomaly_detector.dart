import '../models/telemetry_frame.dart';
import 'anomaly_model.dart';

/// Feeds telemetry into the on-device model and keeps its rolling window.
///
/// Mirrors `backend/src/services/mlDetector.js` so the phone and the server
/// reach the same verdict from the same samples.
///
/// The model is optional throughout. [ready] is false when the asset is
/// missing or malformed, and [accept] then returns null forever — the rule
/// engine remains the floor and monitoring continues unaffected. This is
/// deliberate: a learned model that fails must cost the user nothing.
class AnomalyDetector {
  AnomalyDetector._(this._model);

  final AnomalyModel? _model;
  final List<Map<String, double?>> _buffer = <Map<String, double?>>[];

  /// Loads the bundled model. Never throws.
  static Future<AnomalyDetector> load() async {
    return AnomalyDetector._(await AnomalyModel.load());
  }

  /// Builds a detector around an already-loaded model. Exposed for tests.
  static AnomalyDetector withModel(AnomalyModel? model) {
    return AnomalyDetector._(model);
  }

  bool get ready => _model != null;

  /// Samples needed before the first score can be produced.
  int get window => _model?.window ?? 0;

  /// How full the window currently is, for progress display.
  int get samples => _buffer.length;

  double? get threshold => _model?.threshold;

  void reset() => _buffer.clear();

  /// Feeds one frame and scores the window it completes.
  ///
  /// Returns null when there is no model, the window is not yet full, or the
  /// frame carries no usable vitals.
  AnomalyScore? accept(TelemetryFrame frame) {
    final model = _model;
    if (model == null) return null;

    // A frame the app itself distrusts must not reach the model. Feeding it
    // values flagged as unreliable would manufacture anomalies out of sensor
    // dropout — the finger lifting off would look like a physiological event.
    if (frame.contactState == ContactState.noFinger) return null;

    final sample = <String, double?>{};
    for (final feature in model.features) {
      final value = switch (feature) {
        'HR' => frame.heartRateBpm,
        'SpO2' => frame.spo2Percent,
        _ => null,
      };
      if (value == null) return null; // incomplete — skip, do not pad
      sample[feature] = value;
    }

    _buffer.add(sample);
    if (_buffer.length > model.window) {
      _buffer.removeRange(0, _buffer.length - model.window);
    }

    return model.score(_buffer);
  }
}
