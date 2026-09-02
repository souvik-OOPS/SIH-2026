import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swasthyashield_edge/assistant/engines/assistant_engine.dart';
import 'package:swasthyashield_edge/assistant/engines/knowledge_only_engine.dart';
import 'package:swasthyashield_edge/assistant/models/ai_benchmark_result.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_context.dart';
import 'package:swasthyashield_edge/assistant/models/assistant_request.dart';
import 'package:swasthyashield_edge/assistant/prompts/assistant_system_prompt.dart';
import 'package:swasthyashield_edge/assistant/services/assistant_context_builder.dart';
import 'package:swasthyashield_edge/assistant/services/assistant_service.dart';
import 'package:swasthyashield_edge/assistant/services/local_knowledge_service.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';
import 'package:swasthyashield_edge/core/safety/safety_assessment.dart';
import 'package:swasthyashield_edge/core/telemetry/signal_quality.dart';

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

TelemetryFrame frame({
  double? hr = 115,
  double? spo2 = 96,
  double? at = 40,
  double? rh = 70,
  int quality = 92,
  String contact = 'finger',
  TelemetrySourceType source = TelemetrySourceType.ble,
}) {
  return TelemetryParser.tryParseMap(
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
      'sos': 0,
    },
    sourceType: source,
    connectivity: TelemetryConnectivity.connected,
  )!;
}

const _corpus = '''
[
  {"id":"signal_poor","title":"Poor signal quality","language":"en",
   "keywords":["poor","signal","confidence","unreliable","reliable"],
   "question":"Is my sensor signal reliable?",
   "answer":"Poor signal means the sensor reading cannot be trusted.",
   "category":"sensor"},
  {"id":"heat_warning","title":"Heat stress","language":"en",
   "keywords":["heat","hot","warning","humidity"],
   "question":"Why am I getting this warning?",
   "answer":"Hot humid air stops sweat evaporating. Move to shade and sip water.",
   "category":"heat"},
  {"id":"fall_detected","title":"Fall detected","language":"en",
   "keywords":["fall","fell","impact"],
   "question":"What should I do now?",
   "answer":"A possible fall was detected. Check on the person immediately.",
   "category":"falls"},
  {"id":"signal_poor_hi","title":"सिग्नल की गुणवत्ता","language":"hi",
   "keywords":["सिग्नल","भरोसा","खराब"],
   "question":"क्या सेंसर सिग्नल भरोसेमंद है?",
   "answer":"खराब सिग्नल का मतलब है कि रीडिंग पर भरोसा नहीं किया जा सकता।",
   "category":"sensor"}
]
''';

Future<LocalKnowledgeService> loadedKnowledge({String? corpus}) async {
  final service = LocalKnowledgeService(
    loader: (_) async => corpus ?? _corpus,
    opener: () => databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
  );
  await service.load();
  return service;
}

/// Stands in for an on-device model without needing one.
class FakeEngine implements AssistantEngine {
  FakeEngine({
    this.reply = 'ok',
    this.unavailableReason,
    this.throwOnGenerate = false,
  });

  final String reply;
  final String? unavailableReason;
  final bool throwOnGenerate;

  bool _ready = false;
  int initializeCalls = 0;
  AssistantRequest? lastRequest;

  @override
  String get displayName => 'Fake engine';

  @override
  bool get isReady => _ready;

  @override
  AiBenchmarkResult? get lastBenchmark => null;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    final reason = unavailableReason;
    if (reason != null) throw AssistantEngineUnavailable(reason);
    _ready = true;
  }

  @override
  Stream<String> generate(AssistantRequest request) async* {
    lastRequest = request;
    if (throwOnGenerate) {
      throw const AssistantGenerationException('inference crashed');
    }
    for (final word in reply.split(' ')) {
      yield '$word ';
    }
  }

  @override
  Future<void> dispose() async => _ready = false;
}

Future<AssistantService> serviceWith({
  List<AssistantEngine>? engines,
  String? corpus,
}) async {
  final service = AssistantService(
    engines: engines ?? [KnowledgeOnlyEngine(wordDelay: Duration.zero)],
    knowledge: await loadedKnowledge(corpus: corpus),
  );
  await service.initialize();
  return service;
}

// ---------------------------------------------------------------------------

void main() {
  setUpAll(sqfliteFfiInit);

  group('AssistantContextBuilder', () {
    const builder = AssistantContextBuilder();

    test('maps telemetry into the structured contract', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalQualityLevel.good,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(context.heartRate, 115);
      expect(context.spo2, 96);
      expect(context.ambientTemperature, 40);
      expect(context.humidity, 70);
      expect(context.signalQuality, 'good');
      expect(context.telemetryAvailable, isTrue);
    });

    test('never presents ambient air as body temperature', () {
      final context = builder.build(frame: frame(at: 40));

      // No body-temperature sensor is fitted, so this must stay null rather
      // than borrowing the ambient reading.
      expect(context.temperature, isNull);
      expect(context.ambientTemperature, 40);
      expect(context.toPromptBlock(), contains('bodyTemperature: unavailable'));
    });

    test('reports NOT_COMPUTED when no RiskEngine has run', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalQualityLevel.good,
      );

      expect(context.riskLevel, RiskLevel.notComputed);
      expect(context.fallDetected, isFalse);
      expect(context.reasons, isEmpty);
      expect(context.timeToThresholdMinutes, isNull);
    });

    test('takes every safety field only from the RiskEngine', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalQualityLevel.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.warning,
          timeToThresholdMinutes: 35,
          reasons: ['heart_rate_above_baseline', 'heat_strain_rising'],
        ),
      );

      expect(context.riskLevel, RiskLevel.warning);
      expect(context.timeToThresholdMinutes, 35);
      expect(context.reasons, [
        'heart_rate_above_baseline',
        'heat_strain_rising',
      ]);
    });

    test('matches the documented JSON shape', () {
      final json = builder
          .build(
            frame: frame(),
            signalTier: SignalQualityLevel.good,
            safety: const SafetyAssessment(
              riskLevel: RiskLevel.warning,
              timeToThresholdMinutes: 35,
              reasons: ['heat_strain_rising'],
            ),
          )
          .toJson();

      expect(json['riskLevel'], 'WARNING');
      expect(json['heartRate'], 115);
      expect(json['spo2'], 96);
      expect(json['ambientTemperature'], 40);
      expect(json['humidity'], 70);
      expect(json['signalQuality'], 'good');
      expect(json['fallDetected'], false);
      expect(json['timeToThresholdMinutes'], 35);
      expect(json['reasons'], ['heat_strain_rising']);
    });

    test('missing telemetry yields an explicit no-telemetry context', () {
      final context = builder.build(
        frame: null,
        connectivity: TelemetryConnectivity.disconnected,
      );

      expect(context.telemetryAvailable, isFalse);
      expect(context.heartRate, isNull);
      expect(context.riskLevel, RiskLevel.notComputed);
      expect(context.readingsUnreliable, isTrue);
    });

    test('null sensor values survive as null, never as zero', () {
      final context = builder.build(
        frame: frame(hr: null, spo2: null),
        signalTier: SignalQualityLevel.fair,
      );

      expect(context.heartRate, isNull);
      expect(context.spo2, isNull);
      expect(context.toPromptBlock(), contains('heartRate: unavailable'));
    });

    test('poor signal and stale data both mark readings unreliable', () {
      expect(
        builder
            .build(frame: frame(), signalTier: SignalQualityLevel.poor)
            .readingsUnreliable,
        isTrue,
      );
      expect(
        builder
            .build(
              frame: frame(),
              signalTier: SignalQualityLevel.good,
              isStale: true,
            )
            .readingsUnreliable,
        isTrue,
      );
    });
  });

  group('engine selection', () {
    test('uses the first engine that initializes', () async {
      final preferred = FakeEngine(reply: 'from preferred');
      final fallback = FakeEngine(reply: 'from fallback');

      final service = await serviceWith(engines: [preferred, fallback]);

      expect(service.engine, same(preferred));
      expect(service.isReady, isTrue);
    });

    test('falls through when the preferred engine is unsupported', () async {
      final qualcomm = FakeEngine(
        unavailableReason: 'This device does not have a Qualcomm NPU.',
      );
      final fallback = KnowledgeOnlyEngine(wordDelay: Duration.zero);

      final service = await serviceWith(engines: [qualcomm, fallback]);

      expect(service.engine, same(fallback));
      expect(service.isReady, isTrue);
      expect(service.usesLlm, isFalse);
      expect(service.engineFailureReason, contains('Qualcomm NPU'));
    });

    test('an engine that throws is skipped, not propagated', () async {
      final broken = FakeEngine(unavailableReason: 'boom');
      final service = await serviceWith(
        engines: [
          broken,
          KnowledgeOnlyEngine(wordDelay: Duration.zero),
        ],
      );

      expect(service.isReady, isTrue);
    });
  });

  group('knowledge search (SQLite FTS)', () {
    test('finds the entry matching the question', () async {
      final knowledge = await loadedKnowledge();

      final results = await knowledge.search('is my sensor signal reliable?');

      expect(results, isNotEmpty);
      expect(results.first.id, 'signal_poor');
    });

    test('retrieves by language, keeping Hindi and English separate', () async {
      final knowledge = await loadedKnowledge();

      final english = await knowledge.search('signal');
      final hindi = await knowledge.search(
        'सिग्नल',
        language: AssistantLanguage.hindi,
      );

      expect(english.every((entry) => entry.language == 'en'), isTrue);
      expect(hindi, isNotEmpty);
      expect(hindi.first.language, 'hi');
    });

    test('answers a question made entirely of common words', () async {
      final knowledge = await loadedKnowledge();

      // Every word here is a stop word under the full filter; the question
      // is still one of the app's own suggested questions.
      final results = await knowledge.search('What should I do now?');

      expect(results, isNotEmpty);
      expect(results.first.id, 'fall_detected');
    });

    test('returns nothing rather than an irrelevant entry', () async {
      final knowledge = await loadedKnowledge();

      expect(await knowledge.search('quarterly revenue forecast'), isEmpty);
    });

    test('a corrupt corpus degrades to empty instead of throwing', () async {
      final knowledge = await loadedKnowledge(corpus: 'not json');

      expect(knowledge.entryCount, 0);
      expect(await knowledge.search('signal'), isEmpty);
    });

    test('entries missing required fields are dropped', () async {
      final knowledge = await loadedKnowledge(
        corpus: '[{"id":"x"},{"answer":"y"}]',
      );

      expect(knowledge.entryCount, 0);
    });
  });

  group('prompt construction', () {
    test('carries the exact required standing rules', () {
      expect(
        AssistantSystemPrompt.base,
        contains("The application's RiskEngine is authoritative."),
      );
      expect(
        AssistantSystemPrompt.base,
        contains('Never change or override the supplied risk level.'),
      );
      expect(
        AssistantSystemPrompt.base,
        contains('Never invent sensor measurements.'),
      );
      expect(AssistantSystemPrompt.base, contains('Never diagnose diseases.'));
    });

    test('CRITICAL gets a lead-with-the-instruction rule', () {
      const context = AssistantContext(riskLevel: RiskLevel.critical);
      final prompt = AssistantSystemPrompt.forContext(context);

      expect(prompt, contains('CRITICAL'));
      expect(prompt.toLowerCase(), contains('do not reassure'));
      expect(prompt.toLowerCase(), contains('minimize'));
    });

    test('WARNING and WATCH get their own distinct instructions', () {
      expect(
        AssistantSystemPrompt.forContext(
          const AssistantContext(riskLevel: RiskLevel.warning),
        ),
        contains('what the user must do now'),
      );
      expect(
        AssistantSystemPrompt.forContext(
          const AssistantContext(riskLevel: RiskLevel.watch),
        ),
        contains('preventative action'),
      );
    });

    test('poor signal adds the unreliable-readings rule', () {
      expect(
        AssistantSystemPrompt.forContext(
          const AssistantContext(signalQuality: 'poor'),
        ),
        contains('may be unreliable'),
      );
    });

    test('the turn orders knowledge, state, then question', () {
      final request = AssistantRequest(
        question: 'What should I do now?',
        context: const AssistantContext(riskLevel: RiskLevel.warning),
        systemPrompt: 'sys',
        knowledgeSnippets: const ['- FOO: bar'],
      );
      final prompt = request.toPrompt();

      expect(
        prompt.indexOf('LOCAL KNOWLEDGE:'),
        lessThan(prompt.indexOf('CURRENT DEVICE STATE:')),
      );
      expect(
        prompt.indexOf('CURRENT DEVICE STATE:'),
        lessThan(prompt.indexOf('USER QUESTION:')),
      );
      expect(prompt, contains('riskLevel: WARNING'));
    });

    test('the requested answer language reaches the prompt', () {
      final request = AssistantRequest(
        question: 'q',
        context: const AssistantContext(),
        systemPrompt: 'sys',
        language: AssistantLanguage.hindi,
      );

      expect(request.toPrompt(), contains('ANSWER IN: Hindi'));
      expect(
        AssistantSystemPrompt.forContext(
          const AssistantContext(),
          language: AssistantLanguage.hindi,
        ),
        contains('Answer only in Hindi'),
      );
    });
  });

  group('fallback behaviour', () {
    test('with no LLM the assistant answers from the knowledge base', () async {
      final service = await serviceWith();

      final answer = await service.ask('is my sensor signal reliable?');

      expect(answer, contains('cannot be trusted'));
      expect(service.isReady, isTrue);
      expect(service.usesLlm, isFalse);
      // Prompt formatting is for the model, never for the screen.
      expect(answer, isNot(startsWith('-')));
      expect(answer, isNot(contains('POOR SIGNAL QUALITY:')));
    });

    test('with no match it still returns a deterministic answer', () async {
      final service = await serviceWith();

      final answer = await service.ask(
        'quarterly revenue forecast',
        context: const AssistantContext(heartRate: 115, spo2: 96),
      );

      expect(answer, contains('do not have that information offline'));
      expect(answer, contains('115'));
      expect(answer, contains('has not calculated a risk level'));
    });

    test(
      'a generation failure falls back instead of surfacing an error',
      () async {
        final service = await serviceWith(
          engines: [FakeEngine(throwOnGenerate: true)],
        );

        final answer = await service.ask('is my sensor signal reliable?');

        expect(answer, contains('cannot be trusted'));
        expect(service.messages.last.isStoredAnswer, isTrue);
      },
    );

    test('an empty reply falls back rather than showing blank', () async {
      final service = await serviceWith(engines: [FakeEngine(reply: '   ')]);

      final answer = await service.ask('is my sensor signal reliable?');

      expect(answer.trim(), isNotEmpty);
    });

    test('streaming accumulates tokens into the final answer', () async {
      final service = await serviceWith(
        engines: [FakeEngine(reply: 'move to shade and drink water')],
      );

      final answer = await service.ask('what should I do now?');

      expect(answer, 'move to shade and drink water');
      expect(service.streamingText, isEmpty, reason: 'cleared when done');
      expect(service.isGenerating, isFalse);
    });
  });

  group('demo scenarios', () {
    const builder = AssistantContextBuilder();

    test('1. normal telemetry', () {
      final context = builder.build(
        frame: frame(hr: 72, spo2: 98, at: 28),
        signalTier: SignalQualityLevel.good,
        safety: const SafetyAssessment(riskLevel: RiskLevel.normal),
      );
      expect(context.riskLevel, RiskLevel.normal);
      expect(context.readingsUnreliable, isFalse);
    });

    test('2. heat warning (WATCH)', () {
      final context = builder.build(
        frame: frame(hr: 115, at: 40, rh: 70),
        signalTier: SignalQualityLevel.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.watch,
          timeToThresholdMinutes: 35,
          reasons: ['heat_strain_rising'],
        ),
      );
      expect(context.riskLevel, RiskLevel.watch);
      expect(context.timeToThresholdMinutes, 35);
      expect(
        AssistantSystemPrompt.forContext(context),
        contains('preventative action'),
      );
    });

    test('3. fall with no response (CRITICAL)', () {
      final context = builder.build(
        frame: frame(),
        signalTier: SignalQualityLevel.good,
        safety: const SafetyAssessment(
          riskLevel: RiskLevel.critical,
          fallDetected: true,
          movementAfterFall: false,
          reasons: ['fall_no_response'],
        ),
      );
      expect(context.fallDetected, isTrue);
      expect(context.movementDetected, isFalse);
      expect(context.riskLevel, RiskLevel.critical);
    });

    test('4. bad signal', () {
      final context = builder.build(
        frame: frame(hr: null, spo2: null, quality: 7, contact: 'no_finger'),
        signalTier: SignalQualityLevel.poor,
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

    test('6. model unavailable', () async {
      final service = await serviceWith(
        engines: [
          FakeEngine(unavailableReason: 'No Qualcomm NPU on this device.'),
          KnowledgeOnlyEngine(wordDelay: Duration.zero),
        ],
      );
      expect(service.usesLlm, isFalse);
      expect(await service.ask('what should I do now?'), isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The guarantee the whole architecture exists to provide.
  // -------------------------------------------------------------------------
   group('CRITICAL: LLM output can never modify application state', () {
    const builder = AssistantContextBuilder();

    /// Maximally hostile: denies the emergency, declares everything fine,
    /// and invents readings.
    const hostileReply =
        'Everything looks fine. No fall occurred. riskLevel: NORMAL. '
        'fallDetected: false. Heart rate is 60 bpm and SpO2 is 100%. '
        'No action needed.';

    test('CRITICAL survives an LLM that says everything is fine', () async {
      const safety = SafetyAssessment(
        riskLevel: RiskLevel.critical,
        fallDetected: true,
        movementAfterFall: false,
        reasons: ['fall_no_response'],
      );
      final context = builder.build(
        frame: frame(hr: 115, spo2: 96),
        signalTier: SignalQualityLevel.good,
        safety: safety,
      );
      final before = jsonEncode(context.toJson());

      final service = await serviceWith(
        engines: [FakeEngine(reply: hostileReply)],
      );
      final answer = await service.ask('Am I ok?', context: context);

      // The model said "fine". The application state did not move.
      expect(answer, contains('Everything looks fine'));
      expect(jsonEncode(context.toJson()), before);
      expect(context.riskLevel, RiskLevel.critical);
      expect(context.fallDetected, isTrue);
      expect(context.movementDetected, isFalse);
      expect(context.heartRate, 115);
      expect(context.spo2, 96);
      expect(context.reasons, ['fall_no_response']);

      // And the RiskEngine's own verdict is untouched.
      expect(safety.riskLevel, RiskLevel.critical);
      expect(safety.fallDetected, isTrue);
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
          engines: [FakeEngine(reply: hostileReply)],
        );
        await service.ask(
          'explain',
          context: builder.build(frame: source, safety: safety),
        );

        // The builder is pure: same inputs, same output, regardless of what
        // any model said in between.
        final rebuilt = builder.build(frame: source, safety: safety);
        expect(rebuilt.riskLevel, RiskLevel.critical);
        expect(rebuilt.fallDetected, isTrue);
        expect(rebuilt.heartRate, 118);
        expect(rebuilt.spo2, 89);
      },
    );

    test(
      'the engine receives state but has no channel to write it back',
      () async {
        final engine = FakeEngine(reply: hostileReply);
        final context = builder.build(
          frame: frame(),
          safety: const SafetyAssessment(riskLevel: RiskLevel.critical),
        );

        final service = await serviceWith(engines: [engine]);
        await service.ask('status?', context: context);

        // The engine saw the risk level...
        expect(engine.lastRequest, isNotNull);
        expect(
          engine.lastRequest!.toPrompt(),
          contains('riskLevel: CRITICAL'),
        );
        // ...and generate() returns a Stream<String>. There is no setter, no
        // callback and no out-parameter by which a reply could reach state.
        expect(
          engine.generate,
          isA<Stream<String> Function(AssistantRequest)>(),
        );
        expect(context.riskLevel, RiskLevel.critical);
      },
    );

    test('ask() returns display text only', () async {
      final service = await serviceWith(
        engines: [FakeEngine(reply: hostileReply)],
      );

      expect(
        service.ask,
        isA<Future<String> Function(String, {AssistantContext? context})>(),
      );
    });
  });
}
