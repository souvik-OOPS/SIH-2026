/// Which answering capability the assistant actually has right now.
///
/// Resolved once at startup by `AiEngineSelector` and re-resolved after a
/// model download. The UI shows this so a user is never left guessing whether
/// an answer came from a model or from the bundled knowledge base.
enum AssistantMode {
  /// The OS built-in model (Gemini Nano / Apple Foundation Models).
  builtIn,

  /// A downloaded Gemma 3 270M `.litertlm` running locally.
  downloadedModel,

  /// No LLM. Answers come verbatim from the local knowledge base.
  localKnowledgeOnly,

  /// Nothing works — not even knowledge lookup. The app still monitors.
  unavailable,
}

extension AssistantModeLabel on AssistantMode {
  String get label => switch (this) {
    AssistantMode.builtIn => 'On-device AI',
    AssistantMode.downloadedModel => 'Offline model',
    AssistantMode.localKnowledgeOnly => 'Offline guide',
    AssistantMode.unavailable => 'Unavailable',
  };

  /// Every mode runs without a network, which is the whole point.
  bool get worksOffline => this != AssistantMode.unavailable;

  /// True when a language model is producing the words.
  bool get usesLlm =>
      this == AssistantMode.builtIn || this == AssistantMode.downloadedModel;
}
