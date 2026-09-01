import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_source.dart';
import 'package:swasthyashield_edge/services/replay_telemetry_source.dart';

void main() {
  late Map<String, String> assets;

  setUp(() {
    assets = {
      ReplayScenario.normal.assetPath: _fixture(70),
      ReplayScenario.heatWarning.assetPath: _fixture(105),
      ReplayScenario.fallNonresponse.assetPath: _fixture(86),
      ReplayScenario.badSignal.assetPath: _fixture(null, quality: 0.12),
    };
  });

  ReplayTelemetrySource createSource({
    ReplayScenario scenario = ReplayScenario.normal,
  }) {
    return ReplayTelemetrySource(
      initialScenario: scenario,
      assetLoader: (path) async => assets[path]!,
    );
  }

  test('starts, continuously emits, and stops cleanly', () async {
    final source = createSource();
    final received = <TelemetryFrame>[];
    final subscription = source.frames.listen(received.add);
    source.setPlaybackSpeed(8);

    await source.start();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(received, isNotEmpty);

    await source.stop();
    final countAtStop = received.length;
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(received.length, countAtStop);

    await subscription.cancel();
    await source.dispose();
  });

  test(
    'restart returns a running scenario to its first fixture frame',
    () async {
      assets[ReplayScenario.normal.assetPath] = jsonEncode({
        'intervalMs': 100,
        'frames': [_frame(70), _frame(72)],
      });
      final source = createSource();
      final received = <TelemetryFrame>[];
      final subscription = source.frames.listen(received.add);
      source.setPlaybackSpeed(8);

      await source.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await source.restart();

      expect(received.last.heartRateBpm, 70);

      await subscription.cancel();
      await source.dispose();
    },
  );

  test('switches scenarios while running', () async {
    final source = createSource();
    final received = <TelemetryFrame>[];
    final subscription = source.frames.listen(received.add);

    await source.start();
    await source.switchScenario(ReplayScenario.heatWarning);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(received.last.heartRateBpm, 105);
    expect(received.last.sourceType, TelemetrySourceType.replay);

    await subscription.cancel();
    await source.dispose();
  });

  test(
    'skips malformed fixture entries and continues with valid frames',
    () async {
      assets[ReplayScenario.normal.assetPath] = jsonEncode({
        'intervalMs': 100,
        'frames': [
          'not a frame',
          {'ts': 1788249600, 'hr': 70},
          _frame(76),
        ],
      });
      final source = createSource();
      final received = <TelemetryFrame>[];
      final subscription = source.frames.listen(received.add);

      await source.start();
      expect(received.single.heartRateBpm, 76);

      await subscription.cancel();
      await source.dispose();
    },
  );

  test('all shipped fixtures parse into replay-compatible frames', () async {
    for (final scenario in ReplayScenario.all) {
      final document = jsonDecode(
        await File(scenario.assetPath).readAsString(),
      );
      final rawFrames =
          (document as Map<String, dynamic>)['frames'] as List<dynamic>;

      final parsed = rawFrames
          .whereType<Map<String, dynamic>>()
          .map(
            (frame) => TelemetryFrame.tryParseMap(
              frame,
              sourceType: TelemetrySourceType.replay,
              connectivity: TelemetryConnectivity.connected,
            ),
          )
          .whereType<TelemetryFrame>()
          .toList();

      expect(
        parsed,
        isNotEmpty,
        reason: '${scenario.id} should contain valid frames',
      );
    }
  });
}

String _fixture(double? heartRate, {double quality = 0.95}) => jsonEncode({
  'intervalMs': 100,
  'frames': [
    _frame(heartRate, quality: quality),
    _frame(heartRate, quality: quality),
  ],
});

Map<String, Object?> _frame(double? heartRate, {double quality = 0.95}) => {
  'ts': 1788249600,
  'hr': heartRate,
  'spo2': 98,
  'at': 28.4,
  'rh': 56,
  'ax': 0.1,
  'ay': 0.2,
  'az': 1.0,
  'gx': 2,
  'gy': 3,
  'gz': 4,
  'q': quality,
  'contact': 'finger',
  'sos': 0,
};
