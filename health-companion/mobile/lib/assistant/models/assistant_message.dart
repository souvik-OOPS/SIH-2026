import 'assistant_mode.dart';

enum AssistantMessageRole { user, assistant, system }

/// One line of the conversation.
///
/// [mode] records which capability produced an assistant reply, so the UI can
/// label a knowledge-base answer differently from a generated one. A user
/// deserves to know when they are reading a stored answer.
class AssistantMessage {
  const AssistantMessage({
    required this.role,
    required this.text,
    required this.at,
    this.mode,
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
    AssistantMode? mode,
    DateTime? at,
    List<String> knowledgeSourceIds = const [],
  }) => AssistantMessage(
    role: AssistantMessageRole.assistant,
    text: text,
    at: at ?? DateTime.now(),
    mode: mode,
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
  final AssistantMode? mode;
  final bool isError;
  final List<String> knowledgeSourceIds;

  bool get isUser => role == AssistantMessageRole.user;
}
