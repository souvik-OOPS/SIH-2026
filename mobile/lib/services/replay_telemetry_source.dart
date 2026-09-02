import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/models/telemetry_frame.dart';
import '../core/telemetry/telemetry_parser.dart';
import '../core/telemetry/telemetry_source.dart';

typedef AssetTextLoader = Future<String> Function(String assetPath);

/// Deterministic, looping telemetry for development and the final demo.
class ReplayTelemetrySource implements TelemetrySource, DemoTelemetryControls {
  ReplayTelemetrySource({
    AssetTextLoader? assetLoader,
    ReplayScenario initialScenario = ReplayScenario.normal,
  }) : _assetLoader = assetLoader ?? rootBundle.loadString,
       _scenario = initialScenario;

  final AssetTextLoader _assetLoader;
  final StreamController<TelemetryFrame> _frames =
      StreamController<TelemetryFrame>.broadcast(sync: true);

  ReplayScenario _scenario;
  _ReplayFixture? _fixture;
  Timer? _timer;
  int _frameIndex = 0;
  bool _running = false;
  double _playbackSpeed = 1;

  @override
  Stream<TelemetryFrame> get frames => _frames.stream;

  @override
  List<ReplayScenario> get scenarios => ReplayScenario.all;

  @override
  double get playbackSpeed => _playbackSpeed;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _fixture = await _loadFixture(_scenario);
    if (!_running || _fixture == null) return;
    _frameIndex = 0;
    _emitCurrentFrame();
    _scheduleNextFrame();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> restart() async {
    if (!_running) {
      await start();
      return;
    }
    _frameIndex = 0;
    _emitCurrentFrame();
    _scheduleNextFrame();
  }

  @override
  Future<void> switchScenario(ReplayScenario scenario) async {
    _scenario = scenario;
    _fixture = await _loadFixture(scenario);
    _frameIndex = 0;
    if (_running) {
      _emitCurrentFrame();
      _scheduleNextFrame();
    }
  }

  @override
  void setPlaybackSpeed(double speed) {
    _playbackSpeed = speed.clamp(0.25, 8).toDouble();
    if (_running) _scheduleNextFrame();
  }

  Future<_ReplayFixture> _loadFixture(ReplayScenario scenario) async {
    final decoded = jsonDecode(await _assetLoader(scenario.assetPath));
    if (decoded is! Map) {
      throw const FormatException('Replay fixture must be a JSON object.');
    }

    final intervalMs = decoded['intervalMs'] is num
        ? (decoded['intervalMs'] as num).toInt()
        : 1000;
    final rawFrames = decoded['frames'];
    if (rawFrames is! List) {
      throw const FormatException('Replay fixture must contain a frames list.');
    }

    final frames = <TelemetryFrame>[];
    for (final rawFrame in rawFrames) {
      if (rawFrame is! Map) continue;
      final frame = TelemetryParser.tryParseMap(
        Map<String, dynamic>.from(rawFrame),
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );
      if (frame != null) frames.add(frame);
    }
    if (frames.isEmpty) {
      throw const FormatException('Replay fixture contains no valid frames.');
    }
    return _ReplayFixture(
      intervalMs: intervalMs.clamp(100, 5000).toInt(),
      frames: frames,
    );
  }

  void _scheduleNextFrame() {
    _timer?.cancel();
    final fixture = _fixture;
    if (!_running || fixture == null) return;
    final delay = Duration(
      milliseconds: (fixture.intervalMs / _playbackSpeed)
          .round()
          .clamp(1, 5000)
          .toInt(),
    );
    _timer = Timer(delay, () {
      if (!_running) return;
      _frameIndex = (_frameIndex + 1) % fixture.frames.length;
      _emitCurrentFrame();
      _scheduleNextFrame();
    });
  }

  void _emitCurrentFrame() {
    final fixture = _fixture;
    if (!_running || fixture == null || _frames.isClosed) return;
    final recorded = fixture.frames[_frameIndex];
    _frames.add(recorded.copyWith(timestamp: DateTime.now().toUtc()));
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}

class _ReplayFixture {
  const _ReplayFixture({required this.intervalMs, required this.frames});

  final int intervalMs;
  final List<TelemetryFrame> frames;
}
