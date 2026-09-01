import 'assistant_context.dart';

/// Everything an engine needs for one turn.
///
/// Assembled by [AssistantService] so engines never reach into application
/// state themselves — they receive a finished, already-interpreted request.
class AssistantRequest {
  const AssistantRequest({
    required this.question,
    required this.context,
    required this.systemPrompt,
    this.knowledgeSnippets = const [],
    this.knowledgeAnswers = const [],
    this.language = AssistantLanguage.english,
    this.maxOutputTokens = 220,
  });

  final String question;
  final AssistantContext context;
  final String systemPrompt;

  /// Prompt-formatted entries (`- TITLE: answer`) for the model.
  final List<String> knowledgeSnippets;

  /// The same entries as raw answer text, for display when there is no model.
  /// Kept separate so prompt formatting never leaks onto the screen.
  final List<String> knowledgeAnswers;
  final AssistantLanguage language;
  final int maxOutputTokens;

  /// The documented prompt order: knowledge, then state, then question.
  String toPrompt() {
    final knowledge = knowledgeSnippets.isEmpty
        ? '(no matching local knowledge entries)'
        : knowledgeSnippets.join('\n\n');

    return 'LOCAL KNOWLEDGE:\n$knowledge\n\n'
        'CURRENT DEVICE STATE:\n${context.toPromptBlock()}\n\n'
        'ANSWER IN: ${language.englishName}\n\n'
        'USER QUESTION:\n$question';
  }
}
