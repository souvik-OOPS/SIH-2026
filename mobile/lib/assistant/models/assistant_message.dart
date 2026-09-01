enum AssistantMessageRole { user, assistant }

/// One line of the conversation.
///
/// [engineName] records which engine produced an assistant reply, so the UI
/// can label a knowledge-base answer differently from a generated one. A user
/// deserves to know when they are reading stored text rather than a model's
/// words.
class AssistantMessage {
  const AssistantMessage({
    required this.role,
    required this.text,
    required this.at,
    this.engineName,
    this.isError = false,
    this.knowledgeSourceIds = const [],
  });

  factory AssistantMessage.user(String text, {DateTime? at}) =>
      AssistantMessage(
        role: AssistantMessageRole.user,
        text: text,
        at: at ?? DateTime.now(),
      );

  factory AssistantMessage.assistant(
    String text, {
    String? engineName,
    DateTime? at,
    List<String> knowledgeSourceIds = const [],
  }) => AssistantMessage(
    role: AssistantMessageRole.assistant,
    text: text,
    at: at ?? DateTime.now(),
    engineName: engineName,
    knowledgeSourceIds: knowledgeSourceIds,
  );

  factory AssistantMessage.error(String text, {DateTime? at}) =>
      AssistantMessage(
        role: AssistantMessageRole.assistant,
        text: text,
        at: at ?? DateTime.now(),
        isError: true,
      );

  final AssistantMessageRole role;
  final String text;
  final DateTime at;
  final String? engineName;
  final bool isError;
  final List<String> knowledgeSourceIds;

  bool get isUser => role == AssistantMessageRole.user;

  /// True when the text came from the approved corpus rather than a model.
  bool get isStoredAnswer => engineName == 'Offline guide';
}
