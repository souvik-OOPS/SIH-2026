import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../models/assistant_context.dart';
import '../models/assistant_message.dart';
import '../models/assistant_mode.dart';
import '../prompts/assistant_system_prompt.dart';
import 'ai_engine_selector.dart';
import 'local_knowledge_service.dart';
import 'model_download_service.dart';

/// Test seam: stands in for the on-device model so the guarantee that model
/// output cannot alter application state is provable without a real LLM.
typedef AssistantResponder = Future<String> Function(String prompt);

/// Orchestrates the offline assistant.
///
/// Everything this class returns is display text. No caller reads its output
/// back into application state, so a wrong, weird, or hostile model reply can
/// change what is *shown* and nothing else — risk level, alerts and readings
/// are computed elsewhere and never round-trip through here.
class AssistantService extends ChangeNotifier {
  AssistantService({
    AiEngineSelector? selector,
    LocalKnowledgeService? knowledge,
    ModelDownloadService? downloads,
    this.generationTimeout = const Duration(seconds: 45),
    @visibleForTesting this._debugResponder,
  }) : _selector = selector ?? AiEngineSelector(),
       knowledge = knowledge ?? LocalKnowledgeService(),
       downloads = downloads ?? ModelDownloadService();

  /// Non-null only in tests.
  final AssistantResponder? _debugResponder;

  final AiEngineSelector _selector;
  final LocalKnowledgeService knowledge;
  final ModelDownloadService downloads;
  final Duration generationTimeout;

  static const _maxTokens = 1024;
  static const _maxOutputTokens = 150;
  static const _temperature = 0.3;

  InferenceModel? _model;
  InferenceChat? _chat;
  AssistantMode _mode = AssistantMode.unavailable;
  EngineSelection? _selection;
  bool _initializing = false;
  bool _generating = false;

  final List<AssistantMessage> _messages = [];

  List<AssistantMessage> get messages => List.unmodifiable(_messages);
  AssistantMode get mode => _mode;
  EngineSelection? get selection => _selection;
  bool get isGenerating => _generating;

  /// Ready means the assistant can answer *something* — a knowledge-only
  /// assistant is still useful and still offline.
  bool get isReady => _mode != AssistantMode.unavailable;

  bool get canOfferDownload =>
      _selection?.canDownloadModel == true && downloads.isConfigured;

  Future<AssistantMode> initialize() async {
    if (_initializing) return _mode;
    _initializing = true;
    try {
      await knowledge.load();
      await downloads.refreshInstalledState();

      final selection = await _selector.select();
      _selection = selection;

      if (selection.mode.usesLlm) {
        final loaded = _debugResponder != null || await _loadModel();
        // A model that will not load falls back rather than failing: the
        // knowledge base still answers, offline, with no LLM.
        _mode = loaded
            ? selection.mode
            : (knowledge.entryCount > 0
                  ? AssistantMode.localKnowledgeOnly
                  : AssistantMode.unavailable);
      } else {
        _mode = knowledge.entryCount > 0
            ? AssistantMode.localKnowledgeOnly
            : AssistantMode.unavailable;
      }
    } on Object catch (error) {
      debugPrint('[assistant] initialize failed: $error');
      _mode = knowledge.entryCount > 0
          ? AssistantMode.localKnowledgeOnly
          : AssistantMode.unavailable;
    } finally {
      _initializing = false;
      notifyListeners();
    }
    return _mode;
  }

  /// One model, one chat. Re-entry closes the previous pair first so a
  /// re-initialize after a download cannot leak a second loaded model.
  Future<bool> _loadModel() async {
    try {
      await _closeModel();
      _model = await FlutterGemma.getActiveModel(maxTokens: _maxTokens);
      _chat = await _model!.createChat(
        temperature: _temperature,
        maxOutputTokens: _maxOutputTokens,
        modelType: ModelType.gemmaIt,
        systemInstruction: AssistantSystemPrompt.base,
      );
      return true;
    } on Object catch (error) {
      debugPrint('[assistant] model load failed: $error');
      await _closeModel();
      return false;
    }
  }

  Future<void> downloadOfflineModel({
    required void Function(int progress) onProgress,
  }) async {
    final ok = await downloads.download(onProgress: onProgress);
    if (!ok) {
      notifyListeners();
      return;
    }
    // Re-resolve so the mode reflects the newly installed model.
    _selection = await _selector.select();
    final loaded = await _loadModel();
    _mode = loaded ? AssistantMode.downloadedModel : _mode;
    notifyListeners();
  }

  /// Answers [message] against [context].
  ///
  /// Always returns text. Never throws: a failure downgrades to the knowledge
  /// base, and a total failure returns a plain deterministic sentence.
  Future<String> ask(String message, {AssistantContext? context}) async {
    final question = message.trim();
    if (question.isEmpty) return 'Please type a question.';

    final state = context ?? const AssistantContext.noTelemetry();
    final matches = knowledge.search(question);

    _messages.add(AssistantMessage.user(question));
    _generating = true;
    notifyListeners();

    String answer;
    var answeredWith = _mode;
    try {
      if (_mode.usesLlm && (_debugResponder != null || _chat != null)) {
        answer = await _generate(question, state, matches);
        if (answer.trim().isEmpty) {
          answer = _knowledgeAnswer(matches, state);
          answeredWith = AssistantMode.localKnowledgeOnly;
        }
      } else {
        answer = _knowledgeAnswer(matches, state);
        answeredWith = AssistantMode.localKnowledgeOnly;
      }
    } on TimeoutException {
      answer = _knowledgeAnswer(matches, state);
      answeredWith = AssistantMode.localKnowledgeOnly;
    } on Object catch (error) {
      debugPrint('[assistant] generation failed: $error');
      answer = _knowledgeAnswer(matches, state);
      answeredWith = AssistantMode.localKnowledgeOnly;
    }

    _messages.add(
      AssistantMessage.assistant(
        answer,
        mode: answeredWith,
        knowledgeSourceIds: matches.map((entry) => entry.id).toList(),
      ),
    );
    _generating = false;
    notifyListeners();
    return answer;
  }

  Future<String> _generate(
    String question,
    AssistantContext context,
    List<KnowledgeEntry> matches,
  ) async {
    final prompt = AssistantSystemPrompt.buildTurn(
      question: question,
      context: context,
      knowledgeSnippets: matches
          .map((entry) => entry.toPromptSnippet())
          .toList(),
    );

    // The per-turn context carries the state-specific rules; the standing
    // rules already live in the session's system instruction.
    final guarded = '${AssistantSystemPrompt.forContext(context)}\n\n$prompt';

    final responder = _debugResponder;
    if (responder != null) {
      return responder(guarded).timeout(generationTimeout);
    }

    final chat = _chat!;
    await chat.addQuery(Message.text(text: guarded, isUser: true));
    final response = await chat.generateChatResponse().timeout(
      generationTimeout,
    );

    return switch (response) {
      TextResponse(:final token) => token,
      ThinkingResponse() => '',
      _ => '',
    };
  }

  /// The non-LLM answer path, and the fallback for every LLM failure.
  String _knowledgeAnswer(
    List<KnowledgeEntry> matches,
    AssistantContext context,
  ) {
    if (matches.isNotEmpty) {
      final best = matches.first;
      final caveat = context.readingsUnreliable
          ? '\n\nNote: sensor confidence is low right now, so current '
                'readings may be unreliable.'
          : '';
      return '${best.answer}$caveat';
    }
    return _deterministicFallback(context);
  }

  /// Final fallback. Deterministic, states-only, no interpretation — it
  /// reports what the app already knows and nothing more.
  static String _deterministicFallback(AssistantContext context) {
    if (!context.telemetryAvailable) {
      return 'I do not have that information offline. Right now the device is '
          'not sending data, so no readings are available.';
    }
    final parts = <String>[
      if (context.heartRate != null)
        'heart rate ${context.heartRate!.toStringAsFixed(0)} bpm',
      if (context.spo2 != null) 'SpO2 ${context.spo2!.toStringAsFixed(0)}%',
      if (context.temperature != null)
        'air temperature ${context.temperature!.toStringAsFixed(1)} C',
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

  Future<void> clearConversation() async {
    _messages.clear();
    try {
      await _chat?.clearHistory();
    } on Object catch (error) {
      debugPrint('[assistant] clearing history failed: $error');
    }
    notifyListeners();
  }

  Future<void> _closeModel() async {
    try {
      await _chat?.close();
    } on Object {
      // Already closed, or the engine is gone; nothing to recover.
    }
    _chat = null;
    _model = null;
  }

  @override
  Future<void> dispose() async {
    await _closeModel();
    super.dispose();
  }
}
