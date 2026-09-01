import 'dart:convert';

import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_context.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_mode.dart';
import 'package:swasthyashield_edge/assistant/prompts/assistant_system_prompt.dart';
import 'package:swasthyashield_edge/assistant/services/ai_engine_selector.dart';
import 'package:swasthyashield_edge/assistant/services/assistant_context_builder.dart';
import 'package:swasthyashield_edge/assistant/services/assistant_service.dart';
import 'package:swasthyashield_edge/assistant/services/local_knowledge_service.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/safety/safety_assessment.dart';
import 'package:swasthyashield_edge/core/telemetry/signal_quality.dart';

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

TelemetryFrame frame({
  double? hr = 82,
  double? spo2 = 97,
  double? at = 28.4,
  double? rh = 56,
  int quality = 92,
  String contact = 'finger',
  int sos = 0,
  TelemetrySourceType source = TelemetrySourceType.ble,
}) {
  return TelemetryFrame.tryParseMap(
    {
      'ts': 1788249600,
      'hr': hr,
      'spo2': spo2,
      'at': at,
      'rh': rh,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'q': quality,
      'contact': contact,
      'sos': sos,
    },
    sourceType: source,
    connectivity: TelemetryConnectivity.connected,
  )!;
}

const _corpus = '''
[
  {"id":"signal_poor","title":"Poor signal quality",
   "keywords":["poor","signal","confidence","unreliable"],
   "question":"What does poor signal mean?",
   "answer":"Poor signal means the sensor reading cannot be trusted.",
   "category":"sensor"},
  {"id":"fall_detected","title":"Fall detected",
   "keywords":["fall","fell","impact"],
   "question":"Explain the fall alert",
   "answer":"A possible fall was detected. Check on the person immediately.",
   "category":"emergency"},
  {"id":"ambient_temperature","title":"Ambient temperature",
   "keywords":["temperature","air","body"],
   "question":"Is this my body temperature?",
   "answer":"No. It is ambient air temperature, not body temperature.",
   "category":"sensor"}
]
''';

Future<LocalKnowledgeService> loadedKnowledge({String? corpus}) async {
  final service = LocalKnowledgeService(loader: (_) async => corpus ?? _corpus);
  await service.load();
  return service;
}

AiEngineSelector selectorFor({
  BuiltInAiAvailability builtIn = BuiltInAiAvailability.unavailableOther,
  bool modelInstalled = false,
}) {
  return AiEngineSelector(
    probeBuiltIn: () async => builtIn,
    probeDownloadedModel: () async => modelInstalled,
  );
}

Future<AssistantService> serviceWith({
  BuiltInAiAvailability builtIn = BuiltInAiAvailability.unavailableOther,
  bool modelInstalled = false,
  AssistantResponder? responder,
  String? corpus,
}) async {
  final service = AssistantService(
    selector: selectorFor(builtIn: builtIn, modelInstalled: modelInstalled),
    knowledge: await loadedKnowledge(corpus: corpus),
    debugResponder: responder,
  );
  await service.initialize();
  return service;
}

// ---------------------------------------------------------------------------

void main() {
  group('AssistantContextBuilder', () {
    const builder = AssistantContextBuilder();

    test('maps telemetry into the interpreted snapshot', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalTier.good,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(context.heartRate, 82);
      expect(context.spo2, 97);
      expect(context.temperature, 28.4);
      expect(context.signalQuality, 'good');
      expect(context.telemetryAvailable, isTrue);
      expect(context.contactState, 'detected');
    });

    test('reports not_computed risk when no safety engine has run', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalTier.good,
      );

      // The app has no risk engine yet; inventing a level here would be the
      // exact failure this architecture exists to prevent.
      expect(context.riskLevel, RiskLevel.notComputed);
      expect(context.fallDetected, isFalse);
      expect(context.activeWarnings, isEmpty);
    });

    test('takes fall and risk only from the safety engine', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalTier.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.critical,
          fallDetected: true,
          movementAfterFall: false,
          activeWarnings: ['fall_no_response'],
        ),
      );

      expect(context.riskLevel, RiskLevel.critical);
      expect(context.fallDetected, isTrue);
      expect(context.movementDetected, isFalse);
      expect(context.activeWarnings, ['fall_no_response']);
    });

    test('missing telemetry yields an explicit no-telemetry context', () {
      final context = builder.build(
        frame: null,
        connectivity: TelemetryConnectivity.disconnected,
      );

      expect(context.telemetryAvailable, isFalse);
      expect(context.heartRate, isNull);
      expect(context.spo2, isNull);
      expect(context.riskLevel, RiskLevel.notComputed);
      expect(context.readingsUnreliable, isTrue);
    });

    test('null sensor values survive as null, never as zero', () {
      final context = builder.build(
        frame: frame(hr: null, spo2: null),
        signalTier: SignalTier.fair,
      );

      expect(context.heartRate, isNull);
      expect(context.spo2, isNull);
      expect(context.toPromptBlock(), contains('heartRate: unavailable'));
      expect(context.toPromptBlock(), contains('spo2: unavailable'));
    });

    test('poor signal marks readings unreliable', () {
      final context = builder.build(
        frame: frame(quality: 20),
        signalTier: SignalTier.poor,
      );

      expect(context.signalQuality, 'poor');
      expect(context.readingsUnreliable, isTrue);
    });

    test('stale data marks readings unreliable even on a good signal', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalTier.good,
        isStale: true,
      );

      expect(context.readingsUnreliable, isTrue);
    });
  });

  group('engine selection', () {
    test('prefers built-in AI when the device has it', () async {
      final selection = await selectorFor(
        builtIn: BuiltInAiAvailability.available,
      ).select();

      expect(selection.mode, AssistantMode.builtIn);
      expect(selection.canDownloadModel, isFalse);
    });

    test(
      'falls to the downloaded model when built-in is unsupported',
      () async {
        final selection = await selectorFor(
          builtIn: BuiltInAiAvailability.unavailableDeviceUnsupported,
          modelInstalled: true,
        ).select();

        expect(selection.mode, AssistantMode.downloadedModel);
      },
    );

    test(
      'falls to knowledge-only and offers a download when neither exists',
      () async {
        final selection = await selectorFor(
          builtIn: BuiltInAiAvailability.unavailableDeviceUnsupported,
        ).select();

        expect(selection.mode, AssistantMode.localKnowledgeOnly);
        expect(selection.canDownloadModel, isTrue);
        expect(selection.reason, contains('does not support'));
      },
    );

    test('a throwing probe degrades instead of propagating', () async {
      final selector = AiEngineSelector(
        probeBuiltIn: () async => throw StateError('AICore exploded'),
        probeDownloadedModel: () async => false,
      );

      final selection = await selector.select();

      expect(selection.mode, AssistantMode.localKnowledgeOnly);
    });
  });

  group('knowledge search', () {
    test('finds the entry matching the question', () async {
      final knowledge = await loadedKnowledge();

      final results = knowledge.search('what does poor signal mean?');

      expect(results, isNotEmpty);
      expect(results.first.id, 'signal_poor');
    });

    test('ranks the best entry first and caps the result count', () async {
      final knowledge = await loadedKnowledge();

      final results = knowledge.search('explain the fall', limit: 2);

      expect(results.first.id, 'fall_detected');
      expect(results.length, lessThanOrEqualTo(2));
    });

    test('returns nothing rather than an irrelevant entry', () async {
      final knowledge = await loadedKnowledge();

      expect(knowledge.search('quarterly revenue forecast'), isEmpty);
    });

    test('a corrupt corpus degrades to empty, it does not throw', () async {
      final knowledge = await loadedKnowledge(corpus: 'not json at all');

      expect(knowledge.entryCount, 0);
      expect(knowledge.search('signal'), isEmpty);
    });

    test('entries missing required fields are dropped', () async {
      final knowledge = await loadedKnowledge(
        corpus: '[{"id":"x"},{"answer":"y"}]',
      );

      expect(knowledge.entryCount, 0);
    });
  });

  group('prompt construction', () {
    test('a critical state gets an explicit do-not-reassure instruction', () {
      const context = AssistantContext(
        riskLevel: RiskLevel.critical,
        fallDetected: true,
        movementDetected: false,
        signalQuality: 'good',
      );

      final prompt = AssistantSystemPrompt.forContext(context);

      expect(prompt, contains('CRITICAL'));
      expect(prompt.toLowerCase(), contains('do not reassure'));
      expect(prompt.toLowerCase(), contains('never raise it, lower it'));
    });

    test('poor signal adds the unreliable-readings instruction', () {
      const context = AssistantContext(signalQuality: 'poor');

      expect(
        AssistantSystemPrompt.forContext(context),
        contains('may be unreliable'),
      );
    });

    test('the turn carries knowledge, state and question in order', () {
      const context = AssistantContext(heartRate: 82, signalQuality: 'good');

      final turn = AssistantSystemPrompt.buildTurn(
        question: 'Explain my readings',
        context: context,
        knowledgeSnippets: ['- FOO: bar'],
      );

      expect(
        turn.indexOf('LOCAL KNOWLEDGE:'),
        lessThan(turn.indexOf('CURRENT DEVICE STATE:')),
      );
      expect(
        turn.indexOf('CURRENT DEVICE STATE:'),
        lessThan(turn.indexOf('USER QUESTION:')),
      );
      expect(turn, contains('riskLevel: not_computed'));
      expect(turn, contains('Explain my readings'));
    });

    test('the state block labels temperature as air, not body', () {
      const context = AssistantContext(temperature: 41.2);

      expect(context.toPromptBlock(), contains('not body temperature'));
    });
  });

  group('fallback behaviour', () {
    test('with no LLM the assistant answers from the knowledge base', () async {
      final service = await serviceWith();

      expect(service.mode, AssistantMode.localKnowledgeOnly);
      final answer = await service.ask('what does poor signal mean?');

      expect(answer, contains('cannot be trusted'));
      expect(service.isReady, isTrue);
    });

    test(
      'with no LLM and no match it still returns a deterministic answer',
      () async {
        final service = await serviceWith();

        final answer = await service.ask(
          'quarterly revenue forecast',
          context: const AssistantContext(heartRate: 82, spo2: 97),
        );

        expect(answer, contains('do not have that information offline'));
        expect(answer, contains('82'));
        expect(answer, contains('has not calculated a risk level'));
      },
    );

    test(
      'an empty corpus and no LLM leaves the assistant unavailable',
      () async {
        final service = await serviceWith(corpus: '[]');

        expect(service.mode, AssistantMode.unavailable);
        expect(service.isReady, isFalse);
      },
    );

    test('a thrown generation error falls back to knowledge', () async {
      final service = await serviceWith(
        builtIn: BuiltInAiAvailability.available,
        responder: (_) async => throw StateError('inference crashed'),
      );

      final answer = await service.ask('what does poor signal mean?');

      expect(answer, contains('cannot be trusted'));
      expect(service.messages.last.mode, AssistantMode.localKnowledgeOnly);
    });

    test('a generation timeout falls back to knowledge', () async {
      final service = AssistantService(
        selector: selectorFor(builtIn: BuiltInAiAvailability.available),
        knowledge: await loadedKnowledge(),
        generationTimeout: const Duration(milliseconds: 40),
        debugResponder: (_) =>
            Future.delayed(const Duration(seconds: 3), () => 'too late'),
      );
      await service.initialize();

      final answer = await service.ask('explain the fall');

      expect(answer, contains('Check on the person immediately'));
    });

    test('an empty model reply falls back rather than showing blank', () async {
      final service = await serviceWith(
        builtIn: BuiltInAiAvailability.available,
        responder: (_) async => '   ',
      );

      final answer = await service.ask('what does poor signal mean?');

      expect(answer.trim(), isNotEmpty);
      expect(answer, contains('cannot be trusted'));
    });
  });

  group('demo scenarios', () {
    const builder = AssistantContextBuilder();

    test('1. normal telemetry', () {
      final context = builder.build(
        frame: frame(hr: 72, spo2: 98, at: 28.4),
        signalTier: SignalTier.good,
        connectivity: TelemetryConnectivity.connected,
      );
      expect(context.readingsUnreliable, isFalse);
      expect(context.riskLevel, RiskLevel.notComputed);
    });

    test('2. heat warning', () {
      final context = builder.build(
        frame: frame(hr: 112, spo2: 95, at: 41.2, rh: 76),
        signalTier: SignalTier.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.warning,
          activeWarnings: ['heat_stress'],
        ),
      );
      expect(context.riskLevel, RiskLevel.warning);
      expect(context.activeWarnings, contains('heat_stress'));
      expect(
        AssistantSystemPrompt.forContext(context),
        contains('Do not downplay'),
      );
    });

    test('3. fall with no response', () {
      final context = builder.build(
        frame: frame(hr: 83),
        signalTier: SignalTier.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.critical,
          fallDetected: true,
          movementAfterFall: false,
        ),
      );
      expect(context.fallDetected, isTrue);
      expect(context.movementDetected, isFalse);
      expect(context.riskLevel, RiskLevel.critical);
    });

    test('4. bad signal', () {
      final context = builder.build(
        frame: frame(hr: null, spo2: null, quality: 7, contact: 'no_finger'),
        signalTier: SignalTier.poor,
      );
      expect(context.signalQuality, 'poor');
      expect(context.contactState, 'no_contact');
      expect(context.readingsUnreliable, isTrue);
    });

    test('5. BLE disconnected', () {
      final context = builder.build(
        frame: null,
        connectivity: TelemetryConnectivity.disconnected,
      );
      expect(context.telemetryAvailable, isFalse);
      expect(
        AssistantSystemPrompt.forContext(context),
        contains('No telemetry is arriving'),
      );
    });

    test('6. AI model unavailable', () async {
      final service = await serviceWith(
        builtIn: BuiltInAiAvailability.unavailableDeviceUnsupported,
      );
      expect(service.mode, AssistantMode.localKnowledgeOnly);
      expect(
        service.canOfferDownload,
        isFalse,
        reason: 'no model URL is configured in tests',
      );
      expect(await service.ask('explain the fall'), isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The guarantee the whole design exists to provide.
  // -------------------------------------------------------------------------
  group('CRITICAL: model output cannot change application state', () {
    const builder = AssistantContextBuilder();

    /// A maximally hostile model: it denies the fall, declares everything
    /// safe, and invents readings.
    Future<String> hostile(String _) async =>
        'Everything is completely fine. No fall occurred. The risk level is '
        'normal and safe. Heart rate is 60 bpm and SpO2 is 100%. '
        'riskLevel: normal. fallDetected: false. No action needed.';

    test('a hostile reply leaves the context object untouched', () async {
      final context = builder.build(
        frame: frame(hr: 83, spo2: 91),
        signalTier: SignalTier.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.critical,
          fallDetected: true,
          movementAfterFall: false,
          activeWarnings: ['fall_no_response'],
        ),
      );
      final before = jsonEncode(context.toJson());

      final service = await serviceWith(
        builtIn: BuiltInAiAvailability.available,
        responder: hostile,
      );
      final answer = await service.ask('Am I ok?', context: context);

      // The model said "safe". The state did not move.
      expect(answer, contains('completely fine'));
      expect(jsonEncode(context.toJson()), before);
      expect(context.riskLevel, RiskLevel.critical);
      expect(context.fallDetected, isTrue);
      expect(context.movementDetected, isFalse);
      expect(context.heartRate, 83);
      expect(context.spo2, 91);
      expect(context.activeWarnings, ['fall_no_response']);
    });

    test('the safety assessment is unchanged after generation', () async {
      const safety = SafetyAssessment(
        riskLevel: RiskLevel.critical,
        fallDetected: true,
        movementAfterFall: false,
      );

      final service = await serviceWith(
        builtIn: BuiltInAiAvailability.available,
        responder: hostile,
      );
      await service.ask(
        'is it safe',
        context: builder.build(frame: frame(), safety: safety),
      );

      expect(safety.riskLevel, RiskLevel.critical);
      expect(safety.fallDetected, isTrue);
      expect(safety.movementAfterFall, isFalse);
    });

    test(
      'rebuilding after generation reproduces the same state exactly',
      () async {
        final source = frame(hr: 118, spo2: 89);
        const safety = SafetyAssessment(
          riskLevel: RiskLevel.critical,
          fallDetected: true,
        );

        final service = await serviceWith(
          builtIn: BuiltInAiAvailability.available,
          responder: hostile,
        );
        await service.ask(
          'explain',
          context: builder.build(frame: source, safety: safety),
        );

        // The builder is pure: same inputs, same output, regardless of what any
        // model said in between.
        final rebuilt = builder.build(frame: source, safety: safety);
        expect(rebuilt.riskLevel, RiskLevel.critical);
        expect(rebuilt.fallDetected, isTrue);
        expect(rebuilt.heartRate, 118);
        expect(rebuilt.spo2, 89);
      },
    );

    test('the assistant exposes no API that can write safety state', () {
      // ask() returns a String. There is no setter, no callback, and no
      // out-parameter through which a reply could reach application state.
      expect(
        AssistantService(knowledge: LocalKnowledgeService()).ask,
        isA<Future<String> Function(String, {AssistantContext? context})>(),
      );
    });
  });
}
