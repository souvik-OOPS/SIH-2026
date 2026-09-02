import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_context.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/safety/risk_engine.dart';
import 'package:swasthyashield_edge/core/safety/safety_assessment.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_source.dart';

Future<List<TelemetryFrame>> fixtureFrames(ReplayScenario scenario) async {
  final document = jsonDecode(await File(scenario.assetPath).readAsString())
      as Map<String, dynamic>;
  return (document['frames'] as List<dynamic>)
      .whereType<Map<String, dynamic>>()
      .map(
        (raw) => TelemetryParser.tryParseMap(
          raw,
          sourceType: TelemetrySourceType.replay,
          connectivity: TelemetryConnectivity.connected,
        ),
      )
      .whereType<TelemetryFrame>()
      .toList(growable: false);
}

SafetyAssessment assess(RiskEngine engine, TelemetryFrame frame) => engine.assess(
  frame,
  connectivity: TelemetryConnectivity.connected,
  isStale: false,
);

void main() {
  group('Day 6 deterministic replay scenarios', () {
    test('normal remains NORMAL with reliable trust', () async {
      final engine = RiskEngine();
      final assessments = (await fixtureFrames(ReplayScenario.normal))
          .map((frame) => assess(engine, frame))
          .toList(growable: false);

      expect(assessments, isNotEmpty);
      expect(
        assessments.every((result) => result.riskLevel == RiskLevel.normal),
        isTrue,
      );
      expect(
        assessments.every(
          (result) => result.sensorTrust.state == SensorTrustState.reliable,
        ),
        isTrue,
      );
      expect(assessments.last.score, lessThan(20));
    });

    test('heat progresses from NORMAL through WATCH to WARNING', () async {
      final engine = RiskEngine();
      final assessments = (await fixtureFrames(ReplayScenario.heatWarning))
          .map((frame) => assess(engine, frame))
          .toList(growable: false);
      final levels = assessments.map((result) => result.riskLevel).toList();

      expect(levels.first, RiskLevel.normal);
      expect(levels, contains(RiskLevel.watch));
      expect(levels.last, RiskLevel.warning);
      expect(
        assessments.last.explanations.map((reason) => reason.code),
        containsAll(['heat_exposure', 'heart_rate_deviation']),
      );
    });

    test('bad optical data reacquires instead of producing false CRITICAL', () async {
      final engine = RiskEngine();
      final assessments = (await fixtureFrames(ReplayScenario.badSignal))
          .map((frame) => assess(engine, frame))
          .toList(growable: false);

      expect(
        assessments.every((result) => result.riskLevel != RiskLevel.critical),
        isTrue,
      );
      expect(
        assessments.any(
          (result) => result.sensorTrust.state == SensorTrustState.reacquiring,
        ),
        isTrue,
      );
      expect(
        assessments.any(
          (result) => result.explanations.any(
            (reason) => reason.code == 'reading_unreliable',
          ),
        ),
        isTrue,
      );
    });

    test('fall enters the check-in workflow and then escalates if unanswered',
        () async {
      final engine = RiskEngine();
      final frames = await fixtureFrames(ReplayScenario.fallNonresponse);
      final assessments = frames
          .map((frame) => assess(engine, frame))
          .toList(growable: false);

      expect(assessments.last.riskLevel, RiskLevel.critical);
      expect(assessments.last.fallDetected, isTrue);
      expect(assessments.last.fallState, FallWorkflowState.checkIn);
      expect(
        assessments.last.explanations.map((reason) => reason.code),
        contains('fall_check_in'),
      );

      final unanswered = assess(
        engine,
        frames.last.copyWith(
          timestamp: frames.last.timestamp.add(const Duration(seconds: 31)),
        ),
      );
      expect(unanswered.riskLevel, RiskLevel.critical);
      expect(unanswered.fallState, FallWorkflowState.escalated);
      expect(
        unanswered.explanations.map((reason) => reason.code),
        contains('fall_no_response'),
      );
    });
  });
}
