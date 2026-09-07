import 'dart:async';

import '../models/ai_benchmark_result.dart';
import '../models/assistant_context.dart';
import '../models/assistant_request.dart';
import 'assistant_engine.dart';
import '../services/assistant_response_policy.dart';

/// The always-available engine: no LLM, no model file, no NPU.
///
/// It returns bundled reference text verbatim, or a deterministic
/// summary of state the app already knows. That makes the assistant useful on
/// phones without a local model, and keeps guidance available on failure.
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
    final answer =
        AssistantResponsePolicy.requiredAnswer(request) ??
        (request.knowledgeAnswers.isNotEmpty
            ? _fromKnowledge(request)
            : _deterministic(request));

    for (final word in answer.split(' ')) {
      if (wordDelay > Duration.zero) await Future<void>.delayed(wordDelay);
      yield '$word ';
    }
  }

  String _fromKnowledge(AssistantRequest request) {
    final best = request.knowledgeAnswers.first;
    final caveat = request.context.readingsUnreliable
        ? (request.language == AssistantLanguage.hindi
              ? '\n\nसेंसर की रीडिंग अभी भरोसेमंद नहीं है।'
              : '\n\nThe current sensor readings may be unreliable.')
        : '';
    return '$best$caveat';
  }

  /// States only, no interpretation — it reports what the app already knows.
  static String _deterministic(AssistantRequest request) {
    if (request.language == AssistantLanguage.hindi) {
      return 'इस प्रश्न का भरोसेमंद उत्तर ऑफलाइन गाइड में नहीं मिला।\n\n${AssistantResponsePolicy.status(request)}';
    }
    return 'I do not have that information offline.\n\n${AssistantResponsePolicy.status(request)}';
  }

  @override
  Future<void> dispose() async => _ready = false;
}
