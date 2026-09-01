import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/telemetry_frame.dart';
import '../../core/telemetry/signal_quality.dart';
import '../../core/telemetry/telemetry_source.dart';

/// UI-facing state. It knows only the telemetry and demo-control contracts.
class TelemetrySession extends ChangeNotifier {
  TelemetrySession({
    required this._source,
    this._demoControls,
    this.staleThreshold = const Duration(seconds: 5),
    this.staleCheckInterval = const Duration(seconds: 1),
  });

  /// How long a connected link may go without a frame before it is stale.
  /// Replay runs at ~1.2 Hz and Day 2 BLE at 1 Hz, so this is several
  /// missed frames rather than a single late one.
  final Duration staleThreshold;
  final Duration staleCheckInterval;

  TelemetrySource _source;
  DemoTelemetryControls? _demoControls;

  StreamSubscription<TelemetryFrame>? _subscription;
  Timer? _staleTimer;
  TelemetryFrame? _latestFrame;
  DateTime? _lastFrameAt;
  TelemetryConnectivity _connectivity = TelemetryConnectivity.disconnected;
  Object? _error;
  bool _isRunning = false;
  bool _isStale = false;

  TelemetryFrame? get latestFrame => _latestFrame;
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

  SignalTier get signalTier => classifySignal(
    signalQuality: _latestFrame?.signalQuality ?? 0,
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
    notifyListeners();
  }

  @override
  void dispose() {
    _stopStaleWatch();
    unawaited(_source.stop());
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
