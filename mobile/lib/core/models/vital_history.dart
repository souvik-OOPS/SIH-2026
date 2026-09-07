import 'dart:collection';

/// One point on a vitals trend.
///
/// [bpm] is null when the reading could not be trusted. The point is still
/// recorded, because *when* a sensor lost its grip is information a chart
/// should show rather than hide — a line that glides smoothly over a dropout
/// tells the viewer the wearer was fine during a period the device knew
/// nothing about.
class VitalSample {
  const VitalSample({required this.at, required this.bpm});

  final DateTime at;
  final double? bpm;

  bool get hasValue => bpm != null;
}

/// A fixed-length rolling history of heart rate, for the dashboard trend.
///
/// Bounded on purpose: this exists to draw about two minutes of chart, not to
/// become an unaudited medical record living in RAM. Older points fall off the
/// front as new ones arrive.
class VitalHistory {
  VitalHistory({this.capacity = 120}) : assert(capacity > 1);

  /// How many samples to retain. At roughly 1 Hz this is about two minutes.
  final int capacity;

  final List<VitalSample> _samples = <VitalSample>[];

  UnmodifiableListView<VitalSample> get samples =>
      UnmodifiableListView<VitalSample>(_samples);

  bool get isEmpty => _samples.isEmpty;

  /// Samples that carry an actual reading.
  Iterable<VitalSample> get valued => _samples.where((s) => s.hasValue);

  /// True once there is enough real data to draw a line rather than a dot.
  bool get hasTrend => valued.length >= 2;

  double? get latest => _samples.isEmpty ? null : _samples.last.bpm;

  double? get minimum => valued.isEmpty
      ? null
      : valued.map((s) => s.bpm!).reduce((a, b) => a < b ? a : b);

  double? get maximum => valued.isEmpty
      ? null
      : valued.map((s) => s.bpm!).reduce((a, b) => a > b ? a : b);

  /// Records one reading. Pass null for a sample that cannot be trusted.
  void add({required DateTime at, required double? bpm}) {
    _samples.add(VitalSample(at: at, bpm: bpm));
    if (_samples.length > capacity) {
      _samples.removeRange(0, _samples.length - capacity);
    }
  }

  void clear() => _samples.clear();
}
