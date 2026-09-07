import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/telemetry_frame.dart';
import '../../core/models/vital_history.dart';
import '../../core/ml/anomaly_detector.dart';
import '../../core/ml/anomaly_model.dart';
import '../../core/safety/risk_engine.dart';
import '../../core/safety/safety_assessment.dart';
import '../../core/telemetry/signal_quality.dart';
import '../../core/telemetry/telemetry_source.dart';

/// UI-facing state. It knows only the telemetry and demo-control contracts.
class TelemetrySession extends ChangeNotifier {
  TelemetrySession({
    required TelemetrySource source,
    DemoTelemetryControls? demoControls,
    this.staleThreshold = const Duration(seconds: 5),
    this.staleCheckInterval = const Duration(seconds: 1),
    SignalQualityService? signalQualityService,
    RiskEngine? riskEngine,
    AnomalyDetector? anomalyDetector,
  }) : _anomalyDetector = anomalyDetector,
       _source = source,
       _demoControls = demoControls,
       _signalQualityService = signalQualityService ?? SignalQualityService(),
       _riskEngine = riskEngine ?? RiskEngine();

  /// How long a connected link may go without a frame before it is stale.
  /// Replay runs at ~1.2 Hz and Day 2 BLE at 1 Hz, so this is several
  /// missed frames rather than a single late one.
  final Duration staleThreshold;
  final Duration staleCheckInterval;

  TelemetrySource _source;
  DemoTelemetryControls? _demoControls;
  final SignalQualityService _signalQualityService;
  final RiskEngine _riskEngine;

  /// On-device learned model. Null until [loadModel] completes, and stays null
  /// if the asset is missing — monitoring never depends on it.
  AnomalyDetector? _anomalyDetector;

  StreamSubscription<TelemetryFrame>? _subscription;
  Timer? _staleTimer;
  TelemetryFrame? _latestFrame;
  DateTime? _lastFrameAt;
  TelemetryConnectivity _connectivity = TelemetryConnectivity.disconnected;
  Object? _error;
  bool _isRunning = false;
  bool _isStale = false;
  SafetyAssessment? _safetyAssessment;
  AnomalyScore? _anomalyScore;

  /// Rolling heart-rate trend for the dashboard chart.
  final VitalHistory _heartRateHistory = VitalHistory();

  TelemetryFrame? get latestFrame => _latestFrame;

  /// Heart-rate trend over roughly the last two minutes.
  VitalHistory get heartRateHistory => _heartRateHistory;

  /// The learned model's latest opinion, or null when it has no model, has not
  /// filled its window yet, or the current frame carries no usable vitals.
  ///
  /// This is a second opinion shown alongside the rule verdict. It never
  /// overrides [safetyAssessment]: the model was trained on resting ICU
  /// physiology, it has no diagnostic labels, and it cannot name a condition —
  /// so it may say a window looks unlike normal, never what is wrong.
  AnomalyScore? get anomalyScore => _anomalyScore;

  /// True once the bundled model is loaded and usable.
  bool get anomalyModelReady => _anomalyDetector?.ready ?? false;

  /// How much of the model's window has been gathered, 0..1.
  double get anomalyWindowProgress {
    final detector = _anomalyDetector;
    if (detector == null || !detector.ready || detector.window == 0) return 0;
    return (detector.samples / detector.window).clamp(0.0, 1.0);
  }

  /// Loads the bundled model. Safe to call more than once; never throws.
  Future<void> loadModel() async {
    if (_anomalyDetector != null) return;
    _anomalyDetector = await AnomalyDetector.load();
    notifyListeners();
  }
  TelemetryConnectivity get connectivity => _connectivity;
  Object? get error => _error;
  bool get isRunning => _isRunning;
  bool get supportsDemoControls => _demoControls != null;
  List<ReplayScenario> get scenarios => _demoControls?.scenarios ?? const [];
  double get playbackSpeed => _demoControls?.playbackSpeed ?? 1;

  /// True when the link still reports connected but frames stopped arriving.
  /// Reported separately from [connectivity] so a silent sensor is never
  /// mistaken for a clean disconnect.
  bool get isStale => _isStale;

  DateTime? get lastFrameAt => _lastFrameAt;

  /// The only UI-facing risk verdict. It is rebuilt from every frame and is
  /// deliberately separate from the presentational signal-quality service.
  SafetyAssessment? get safetyAssessment => _safetyAssessment;

  SignalQualityAssessment get signalAssessment => _signalQualityService.assess(
    frame: _latestFrame,
    connectivity: _connectivity,
    isStale: _isStale,
  );

  Future<void> start() async {
    _subscription ??= _source.frames.listen(
      _receiveFrame,
      onError: (Object error, StackTrace stackTrace) {
        _error = error;
        _connectivity = TelemetryConnectivity.disconnected;
        notifyListeners();
      },
    );
    _connectivity = TelemetryConnectivity.connecting;
    _error = null;
    _startStaleWatch();
    notifyListeners();
    try {
      await _source.start();
      _isRunning = true;
      if (_latestFrame == null) notifyListeners();
    } on Object catch (error) {
      _error = error;
      _connectivity = TelemetryConnectivity.disconnected;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _source.stop();
    _stopStaleWatch();
    _isRunning = false;
    _connectivity = TelemetryConnectivity.disconnected;
    notifyListeners();
  }

  Future<void> replaceSource(
    TelemetrySource source, {
    DemoTelemetryControls? demoControls,
  }) async {
    await _source.stop();
    await _subscription?.cancel();
    _subscription = null;
    _stopStaleWatch();
    _source = source;
    _demoControls = demoControls;
    _latestFrame = null;
    _lastFrameAt = null;
    _isStale = false;
    _safetyAssessment = null;
    _riskEngine.reset();
    _anomalyDetector?.reset();
    _anomalyScore = null;
    _heartRateHistory.clear();
    _error = null;
    _isRunning = false;
    _connectivity = TelemetryConnectivity.connecting;
    notifyListeners();
    await start();
  }

  Future<void> restart() async {
    final controls = _demoControls;
    if (controls == null) return;
    _error = null;
    await controls.restart();
  }

  Future<void> switchScenario(ReplayScenario scenario) async {
    final controls = _demoControls;
    if (controls == null) return;
    _error = null;
    await controls.switchScenario(scenario);
  }

  void setPlaybackSpeed(double speed) => _demoControls?.setPlaybackSpeed(speed);

  void _receiveFrame(TelemetryFrame frame) {
    _latestFrame = frame;
    _lastFrameAt = DateTime.now();
    _connectivity = frame.connectivity;
    _isRunning = true;
    _isStale = false;
    // Record the trend point before scoring. A reading the app would not show
    // is stored as a gap rather than dropped: the chart breaks its line there,
    // which says the device had nothing at that moment instead of drawing a
    // confident stretch across it.
    _heartRateHistory.add(
      at: frame.timestamp,
      bpm: frame.contactState == ContactState.noFinger ||
              frame.signalQuality < HeuristicSignalQualityModel.fairConfidence
          ? null
          : frame.heartRateBpm,
    );

    // Score before the rules run so the UI updates both from one frame.
    //
    // Assign unconditionally, including null. Keeping the last score when the
    // detector declines to produce one left a stale verdict on screen
    // indefinitely — the card read "Unlike your normal, 214x past threshold"
    // directly above "No finger contact, 0% confidence". A model that has
    // stopped having an opinion must visibly stop stating one.
    _anomalyScore = _anomalyDetector?.accept(frame);
    _evaluateSafety();
    notifyListeners();
  }

  void _startStaleWatch() {
    _staleTimer ??= Timer.periodic(staleCheckInterval, (_) => _evaluateStale());
  }

  void _stopStaleWatch() {
    _staleTimer?.cancel();
    _staleTimer = null;
    if (_isStale) {
      _isStale = false;
      notifyListeners();
    }
  }

  /// A link only goes stale after it has delivered at least one frame; a
  /// source that has never produced data is still connecting, not stale.
  void _evaluateStale() {
    final last = _lastFrameAt;
    final stale =
        last != null &&
        _connectivity != TelemetryConnectivity.disconnected &&
        DateTime.now().difference(last) > staleThreshold;
    if (stale == _isStale) return;
    _isStale = stale;
    _evaluateSafety();
    notifyListeners();
  }

  void _evaluateSafety() {
    final frame = _latestFrame;
    if (frame == null) {
      _safetyAssessment = null;
      return;
    }
    _safetyAssessment = _riskEngine.assess(
      frame,
      connectivity: _connectivity,
      isStale: _isStale,
    );
  }

  @override
  void dispose() {
    _stopStaleWatch();
    unawaited(_source.stop());
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
