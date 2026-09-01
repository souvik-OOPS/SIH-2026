import 'dart:async';

import '../models/ai_benchmark_result.dart';
import '../models/assistant_context.dart';
import '../models/assistant_request.dart';
import 'assistant_engine.dart';

/// The always-available engine: no LLM, no model file, no NPU.
///
/// It returns approved knowledge-base text verbatim, or a deterministic
/// summary of state the app already knows. That makes the assistant useful on
/// every phone — including the overwhelming majority that cannot run the
/// Qualcomm stack — and guarantees the feature degrades instead of vanishing.
///
/// It streams word by word so the UI path is identical for every engine.
class KnowledgeOnlyEngine implements AssistantEngine {
  KnowledgeOnlyEngine({this.wordDelay = const Duration(milliseconds: 18)});

  /// Purely cosmetic pacing so the chat reads naturally.
  final Duration wordDelay;

  bool _ready = false;

  @override
  String get displayName => 'Offline guide';

  @override
  bool get isReady => _ready;

  /// No model runs here, so there is nothing to benchmark. Reporting null is
  /// the honest answer; a fabricated number would be worse than none.
  @override
  AiBenchmarkResult? get lastBenchmark => null;

  @override
  Future<void> initialize() async => _ready = true;

  @override
  Stream<String> generate(AssistantRequest request) async* {
    final answer = request.knowledgeAnswers.isNotEmpty
        ? _fromKnowledge(request)
        : _deterministic(request.context);

    for (final word in answer.split(' ')) {
      if (wordDelay > Duration.zero) await Future<void>.delayed(wordDelay);
      yield '$word ';
    }
  }

  String _fromKnowledge(AssistantRequest request) {
    final best = request.knowledgeAnswers.first;
    final caveat = request.context.readingsUnreliable
        ? '\n\nNote: sensor confidence is low right now, so the current '
              'readings may be unreliable.'
        : '';
    return '$best$caveat';
  }

  /// States only, no interpretation — it reports what the app already knows.
  static String _deterministic(AssistantContext context) {
    if (!context.telemetryAvailable) {
      return 'I do not have that information offline. The device is not '
          'sending data right now, so no readings are available.';
    }
    final parts = <String>[
      if (context.heartRate != null)
        'heart rate ${context.heartRate!.toStringAsFixed(0)} bpm',
      if (context.spo2 != null) 'SpO2 ${context.spo2!.toStringAsFixed(0)}%',
      if (context.ambientTemperature != null)
        'air temperature ${context.ambientTemperature!.toStringAsFixed(1)} C',
    ];
    final reading = parts.isEmpty
        ? 'No readings are available right now.'
        : 'Latest readings: ${parts.join(', ')}.';
    final risk = context.riskLevel == RiskLevel.notComputed
        ? 'The app has not calculated a risk level.'
        : 'The app reports risk level ${context.riskLevel.wireValue}.';
    final signal = context.readingsUnreliable
        ? ' Sensor confidence is low, so these may be unreliable.'
        : '';
    return 'I do not have that information offline. $reading $risk$signal';
  }

  @override
  Future<void> dispose() async => _ready = false;
}
