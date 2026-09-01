import '../models/telemetry_frame.dart';

abstract interface class TelemetrySource {
  Stream<TelemetryFrame> get frames;

  Future<void> start();

  Future<void> stop();
}

/// Optional controls that a development telemetry source may expose.
/// The dashboard interacts with this interface, never a concrete replay class.
abstract interface class DemoTelemetryControls {
  List<ReplayScenario> get scenarios;

  double get playbackSpeed;

  Future<void> restart();

  Future<void> switchScenario(ReplayScenario scenario);

  void setPlaybackSpeed(double speed);
}

class ReplayScenario {
  const ReplayScenario({
    required this.id,
    required this.label,
    required this.assetPath,
  });

  final String id;
  final String label;
  final String assetPath;

  static const normal = ReplayScenario(
    id: 'normal',
    label: 'Normal',
    assetPath: 'assets/demo/normal.json',
  );
  static const heatWarning = ReplayScenario(
    id: 'heat_warning',
    label: 'Heat Warning',
    assetPath: 'assets/demo/heat_warning.json',
  );
  static const fallNonresponse = ReplayScenario(
    id: 'fall_nonresponse',
    label: 'Fall + Non-response',
    assetPath: 'assets/demo/fall_nonresponse.json',
  );
  static const badSignal = ReplayScenario(
    id: 'bad_signal',
    label: 'Bad Signal',
    assetPath: 'assets/demo/bad_signal.json',
  );

  static const all = [normal, heatWarning, fallNonresponse, badSignal];
}
