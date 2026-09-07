import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../engines/assistant_engine.dart';
import '../engines/knowledge_only_engine.dart';
import '../engines/qualcomm_qwen_engine.dart';
import '../models/ai_benchmark_result.dart';
import '../models/assistant_context.dart';
import '../models/assistant_message.dart';
import '../models/assistant_request.dart';
import '../prompts/assistant_system_prompt.dart';
import 'local_knowledge_service.dart';
import 'assistant_response_policy.dart';

/// Orchestrates the offline assistant.
///
/// Everything this class produces is display text. No caller reads its output
/// back into application state, so a wrong, weird, or actively hostile model
/// reply changes what is *shown* and nothing else. Risk level, alerts, fall
/// state and sensor readings are computed by the RiskEngine and never round
/// trip through here.
///
/// Engines are tried in order and the first that initializes wins. The last
/// engine in the list must always be one that cannot fail, so the assistant
/// degrades instead of disappearing.
class AssistantService extends ChangeNotifier {
  AssistantService({
    List<AssistantEngine>? engines,
    LocalKnowledgeService? knowledge,
    this.generationTimeout = const Duration(seconds: 60),
  }) : knowledge = knowledge ?? LocalKnowledgeService(),
       _engines = engines ?? [QualcommQwenEngine(), KnowledgeOnlyEngine()];

  final List<AssistantEngine> _engines;
  final LocalKnowledgeService knowledge;
  final Duration generationTimeout;

  final List<AssistantMessage> _messages = [];

  AssistantEngine? _engine;
  String? _engineFailureReason;
  AssistantLanguage _language = AssistantLanguage.english;
  bool _initializing = false;
  bool _generating = false;
  String _streamingText = '';
  int _conversationVersion = 0;
  AssistantContext Function()? liveContextProvider;

  List<AssistantMessage> get messages => List.unmodifiable(_messages);
  bool get isGenerating => _generating;

  /// Partial text for the in-flight reply, so the UI can stream it.
  String get streamingText => _streamingText;

  AssistantEngine? get engine => _engine;
  String get engineName => _engine?.displayName ?? 'Unavailable';
  AiBenchmarkResult? get lastBenchmark => _engine?.lastBenchmark;

  /// Why the preferred engine could not be used, for the setup screen.
  String? get engineFailureReason => _engineFailureReason;

  AssistantLanguage get language => _language;
  set language(AssistantLanguage value) {
    if (_language == value) return;
    _language = value;
    notifyListeners();
  }

  /// True when the assistant can answer *something*. A knowledge-only
  /// assistant is still useful, and still fully offline.
  bool get isReady => _engine?.isReady ?? false;

  /// True when a real language model is producing the words.
  bool get usesLlm => _engine is QualcommQwenEngine;

  Future<void> initialize() async {
    if (_initializing) return;
    _initializing = true;
    _engineFailureReason = null;
    try {
      await knowledge.load();

      for (final candidate in _engines) {
        try {
          await candidate.initialize();
          _engine = candidate;
          break;
        } on AssistantEngineUnavailable catch (error) {
          // Expected on most hardware: record why and try the next engine.
          _engineFailureReason ??= error.reason;
          debugPrint('[assistant] ${candidate.displayName}: ${error.reason}');
        } on Object catch (error) {
          _engineFailureReason ??= '$error';
          debugPrint('[assistant] ${candidate.displayName} failed: $error');
        }
      }
    } on Object catch (error) {
      debugPrint('[assistant] initialize failed: $error');
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  /// Answers [message] against [context], streaming as it goes.
  ///
  /// Never throws. A failure mid-stream falls back to the knowledge base so
  /// the user gets an answer rather than an error.
  Future<String> ask(String message, {AssistantContext? context}) async {
    if (_generating) return '';
    final question = message.trim();
    if (question.isEmpty) return '';
    _generating = true;
    final version = _conversationVersion;

    final state = context ?? const AssistantContext.noTelemetry();
    final matches = await knowledge.search(question, language: _language);
    final request = AssistantRequest(
      question: question,
      context: state,
      systemPrompt: AssistantSystemPrompt.forContext(
        state,
        language: _language,
      ),
      knowledgeSnippets: matches.map((e) => e.toPromptSnippet()).toList(),
      knowledgeAnswers: matches.map((e) => e.answer).toList(),
      language: _language,
      conversation: _messages
          .skip(_messages.length > 6 ? _messages.length - 6 : 0)
          .map((m) => '${m.isUser ? 'User' : 'Assistant'}: ${m.text}')
          .toList(),
    );

    _messages.add(AssistantMessage.user(question));
    _generating = true;
    _streamingText = '';
    notifyListeners();

    var answer = '';
    var usedFallback = false;
    var stateAnswer = false;
    try {
      final required = AssistantResponsePolicy.requiredAnswer(request);
      if (required != null) {
        answer = required;
        usedFallback = true;
        stateAnswer = true;
      } else {
        answer = await _stream(_engine, request);
      }
      if (answer.trim().isEmpty) {
        answer = await _stream(
          KnowledgeOnlyEngine(wordDelay: Duration.zero),
          request,
        );
        usedFallback = true;
      }
    } on Object catch (error) {
      debugPrint('[assistant] generation failed: $error');
      try {
        answer = await _stream(
          KnowledgeOnlyEngine(wordDelay: Duration.zero),
          request,
        );
      } on Object {
        answer =
            'The assistant is unavailable right now. Monitoring and '
            'alerts are unaffected.';
      }
      usedFallback = true;
    }

    final latest = liveContextProvider?.call();
    if (latest != null &&
        (latest.riskLevel.isElevated || latest.fallDetected)) {
      answer = AssistantResponsePolicy.status(
        AssistantRequest(
          question: question,
          context: latest,
          systemPrompt: '',
          language: request.language,
        ),
      );
      stateAnswer = true;
    }
    if (version != _conversationVersion) return '';
    _messages.add(
      AssistantMessage.assistant(
        answer.trim(),
        engineName: stateAnswer
            ? 'Live monitoring guide'
            : usedFallback
            ? 'Offline guide'
            : engineName,
        knowledgeSourceIds: stateAnswer
            ? []
            : matches.map((entry) => entry.id).toList(),
        sources: stateAnswer
            ? const []
            : matches
                  .where((e) => e.sourceUrl != null)
                  .map(
                    (e) =>
                        '${e.sourceTitle ?? e.title}\n${e.sourceUrl}${e.reviewedAt == null ? '' : '\nUpdated ${e.reviewedAt}'}',
                  )
                  .toSet()
                  .toList(),
      ),
    );
    _generating = false;
    _streamingText = '';
    notifyListeners();
    return answer.trim();
  }

  Future<String> _stream(
    AssistantEngine? engine,
    AssistantRequest request,
  ) async {
    if (engine == null) {
      throw const AssistantGenerationException('No engine is available.');
    }
    if (!engine.isReady) await engine.initialize();

    final buffer = StringBuffer();
    final done = Completer<void>();
    final subscription = engine
        .generate(request)
        .listen(
          (token) {
            buffer.write(token);
            // Unchecked model tokens are buffered; they never flash unsafe guidance
            // on screen before the final state policy is applied.
            if (engine is KnowledgeOnlyEngine) {
              _streamingText = buffer.toString();
            }
            notifyListeners();
          },
          onError: (Object error, StackTrace stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
    try {
      await done.future.timeout(generationTimeout);
      return buffer.toString();
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> clearConversation() async {
    if (_generating) return;
    _conversationVersion++;
    _messages.clear();
    _streamingText = '';
    notifyListeners();
  }

  Future<void> importLocalModel() async {
    if (_generating || _initializing) return;
    try {
      final imported = await const MethodChannel(
        'in.sih.swasthyashield/ble_permissions',
      ).invokeMethod<bool>('importModel');
      if (imported == true) await initialize();
    } on Object catch (error) {
      _engineFailureReason = 'Model import failed: $error';
      notifyListeners();
    }
  }

  @override
  Future<void> dispose() async {
    for (final engine in _engines) {
      await engine.dispose();
    }
    await knowledge.dispose();
    super.dispose();
  }
}
