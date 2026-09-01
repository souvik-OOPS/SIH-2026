import '../models/telemetry_frame.dart';

/// Coarse trust tier shown on the dashboard.
///
/// Day 3 keeps the calculation deliberately simple; the real Sensor Trust
/// Engine replaces [classifySignal] later without touching any widget.
enum SignalTier { good, fair, poor, reacquiring }

extension SignalTierLabel on SignalTier {
  String get label => switch (this) {
    SignalTier.good => 'GOOD',
    SignalTier.fair => 'FAIR',
    SignalTier.poor => 'POOR',
    SignalTier.reacquiring => 'REACQUIRING',
  };
}

/// Thresholds on the 0.0–1.0 normalized quality carried by a frame.
const double kGoodSignalThreshold = 0.7;
const double kFairSignalThreshold = 0.4;

/// Maps live telemetry state onto a [SignalTier].
///
/// A link that is stale or not connected reports [SignalTier.reacquiring]
/// rather than a stale numeric grade: the last packet's quality says nothing
/// about a link that is no longer delivering packets.
SignalTier classifySignal({
  required double signalQuality,
  required TelemetryConnectivity connectivity,
  required bool isStale,
}) {
  if (isStale || connectivity != TelemetryConnectivity.connected) {
    return SignalTier.reacquiring;
  }
  if (signalQuality >= kGoodSignalThreshold) return SignalTier.good;
  if (signalQuality >= kFairSignalThreshold) return SignalTier.fair;
  return SignalTier.poor;
}
