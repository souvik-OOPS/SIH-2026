import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/telemetry/signal_quality.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_source.dart';
import 'package:swasthyashield_edge/features/monitoring/telemetry_session.dart';

/// Minimal source under the same contract the dashboard consumes, so these
/// tests exercise the session without a radio or an asset bundle.
class _FakeSource implements TelemetrySource {
  final StreamController<TelemetryFrame> _controller =
      StreamController<TelemetryFrame>.broadcast(sync: true);

  int startCount = 0;
  int stopCount = 0;

  @override
  Stream<TelemetryFrame> get frames => _controller.stream;

  @override
  Future<void> start() async => startCount++;

  @override
  Future<void> stop() async => stopCount++;

  void emit(TelemetryFrame frame) => _controller.add(frame);

  Future<void> close() => _controller.close();
}

class _FakeDemoControls implements DemoTelemetryControls {
  @override
  List<ReplayScenario> get scenarios => ReplayScenario.all;
  @override
  double get playbackSpeed => 1;
  @override
  Future<void> restart() async {}
  @override
  Future<void> switchScenario(ReplayScenario scenario) async {}
  @override
  void setPlaybackSpeed(double speed) {}
}

TelemetryFrame _frame({
  double quality = 0.9,
  TelemetrySourceType sourceType = TelemetrySourceType.ble,
  TelemetryConnectivity connectivity = TelemetryConnectivity.connected,
}) {
  return TelemetryFrame.tryParseMap(
    {
      'ts': 1788249600,
      'q': (quality * 100).round(),
      'hr': 72,
      'spo2': 98,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
    },
    sourceType: sourceType,
    connectivity: connectivity,
  )!;
}

void main() {
  group('stale telemetry', () {
    test('a connected link with no frames goes stale, then recovers', () async {
      final source = _FakeSource();
      final session = TelemetrySession(
        source: source,
        staleThreshold: const Duration(milliseconds: 80),
        staleCheckInterval: const Duration(milliseconds: 20),
      );
      addTearDown(source.close);

      await session.start();
      source.emit(_frame());
      expect(session.isStale, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 220));

      expect(
        session.isStale,
        isTrue,
        reason: 'frames stopped arriving well past the threshold',
      );
      expect(
        session.connectivity,
        TelemetryConnectivity.connected,
        reason: 'stale must stay distinct from a real disconnect',
      );

      source.emit(_frame());
      expect(session.isStale, isFalse);

      session.dispose();
    });

    test(
      'a source that never delivered a frame is connecting, not stale',
      () async {
        final source = _FakeSource();
        final session = TelemetrySession(
          source: source,
          staleThreshold: const Duration(milliseconds: 40),
          staleCheckInterval: const Duration(milliseconds: 20),
        );
        addTearDown(source.close);

        await session.start();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(session.isStale, isFalse);
        expect(session.connectivity, TelemetryConnectivity.connecting);

        session.dispose();
      },
    );

    test(
      'stale telemetry reports REACQUIRING rather than a stale grade',
      () async {
        final source = _FakeSource();
        final session = TelemetrySession(
          source: source,
          staleThreshold: const Duration(milliseconds: 60),
          staleCheckInterval: const Duration(milliseconds: 20),
        );
        addTearDown(source.close);

        await session.start();
        source.emit(_frame(quality: 0.95));
        expect(session.signalTier, SignalTier.good);

        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(session.signalTier, SignalTier.reacquiring);

        session.dispose();
      },
    );
  });

  group('source switching', () {
    test('swaps to a new source and consumes only its frames', () async {
      final replay = _FakeSource();
      final live = _FakeSource();
      final session = TelemetrySession(
        source: replay,
        demoControls: _FakeDemoControls(),
      );
      addTearDown(replay.close);
      addTearDown(live.close);

      await session.start();
      replay.emit(_frame(sourceType: TelemetrySourceType.replay));
      expect(session.latestFrame!.sourceType, TelemetrySourceType.replay);
      expect(session.supportsDemoControls, isTrue);

      await session.replaceSource(live);

      expect(replay.stopCount, greaterThan(0), reason: 'old source is stopped');
      expect(live.startCount, 1);
      expect(
        session.supportsDemoControls,
        isFalse,
        reason: 'the live source exposes no fixture controls',
      );

      live.emit(_frame(sourceType: TelemetrySourceType.ble));
      expect(session.latestFrame!.sourceType, TelemetrySourceType.ble);

      // The replaced source must no longer reach the dashboard.
      replay.emit(_frame(quality: 0.1, sourceType: TelemetrySourceType.replay));
      expect(session.latestFrame!.sourceType, TelemetrySourceType.ble);

      session.dispose();
    });

    test('switching back to a demo source restores fixture controls', () async {
      final live = _FakeSource();
      final replay = _FakeSource();
      final session = TelemetrySession(source: live);
      addTearDown(live.close);
      addTearDown(replay.close);

      await session.start();
      expect(session.supportsDemoControls, isFalse);

      await session.replaceSource(replay, demoControls: _FakeDemoControls());

      expect(session.supportsDemoControls, isTrue);
      expect(session.scenarios.length, 4);
      session.dispose();
    });

    test(
      'switching sources clears the previous frame and stale state',
      () async {
        final live = _FakeSource();
        final replay = _FakeSource();
        final session = TelemetrySession(
          source: live,
          staleThreshold: const Duration(milliseconds: 60),
          staleCheckInterval: const Duration(milliseconds: 20),
        );
        addTearDown(live.close);
        addTearDown(replay.close);

        await session.start();
        live.emit(_frame());
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(session.isStale, isTrue);

        await session.replaceSource(replay, demoControls: _FakeDemoControls());

        expect(session.isStale, isFalse);
        expect(session.latestFrame, isNull);
        session.dispose();
      },
    );
  });

  group('signal tiers', () {
    test('grades a connected link by quality', () {
      SignalTier tierFor(double quality) => classifySignal(
        signalQuality: quality,
        connectivity: TelemetryConnectivity.connected,
        isStale: false,
      );

      expect(tierFor(0.95), SignalTier.good);
      expect(tierFor(0.7), SignalTier.good);
      expect(tierFor(0.55), SignalTier.fair);
      expect(tierFor(0.4), SignalTier.fair);
      expect(tierFor(0.2), SignalTier.poor);
    });

    test(
      'a disconnected link is reacquiring whatever the last quality was',
      () {
        expect(
          classifySignal(
            signalQuality: 0.99,
            connectivity: TelemetryConnectivity.disconnected,
            isStale: false,
          ),
          SignalTier.reacquiring,
        );
      },
    );

    test('labels are the states the dashboard renders', () {
      expect(SignalTier.good.label, 'GOOD');
      expect(SignalTier.fair.label, 'FAIR');
      expect(SignalTier.poor.label, 'POOR');
      expect(SignalTier.reacquiring.label, 'REACQUIRING');
    });
  });

  group('malformed and partial packets', () {
    test('a BLE frame with unavailable sensors still parses', () {
      final frame = TelemetryFrame.tryParseMap(
        {
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'v': 1,
          'hr': null,
          'o2': null,
          't': null,
          'h': null,
          'q': 64,
          'f': 0,
        },
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(
        frame,
        isNotNull,
        reason: 'nulls mean "unavailable", not "invalid"',
      );
      expect(frame!.heartRateBpm, isNull);
      expect(frame.spo2Percent, isNull);
      expect(frame.signalQuality, closeTo(0.64, 1e-9));
      expect(frame.contactState, ContactState.noFinger);
    });

    test('a frame without signal quality is rejected', () {
      final frame = TelemetryFrame.tryParseMap(
        {'timestamp': DateTime.now().toUtc().toIso8601String(), 'hr': 72},
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(frame, isNull);
    });
  });
}
