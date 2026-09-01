import 'package:flutter/material.dart';

import '../models/assistant_context.dart';
import '../models/assistant_message.dart';
import '../services/assistant_service.dart';
import '../widgets/assistant_message_bubble.dart';
import '../widgets/assistant_status_badge.dart';
import 'assistant_diagnostics_screen.dart';

/// Chat surface for the offline assistant.
///
/// [contextProvider] is called per question, so every answer is grounded in
/// the state at the moment it was asked without this screen ever subscribing
/// to the telemetry stream itself.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.assistant,
    required this.contextProvider,
  });

  final AssistantService assistant;
  final AssistantContext Function() contextProvider;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  static const _suggestions = [
    'Why am I getting this warning?',
    'Explain my current condition.',
    'What should I do now?',
    'Is my sensor signal reliable?',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final question = text.trim();
    if (question.isEmpty || widget.assistant.isGenerating) return;
    _controller.clear();
    _scrollToEnd();
    await widget.assistant.ask(question, context: widget.contextProvider());
    if (!mounted) return;
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final assistant = widget.assistant;

    return AnimatedBuilder(
      animation: assistant,
      builder: (context, _) {
        final messages = assistant.messages;
        final streaming = assistant.streamingText;
        final riskLevel = widget.contextProvider().riskLevel;
        // The in-flight reply is rendered as a temporary extra bubble.
        final itemCount = messages.length + (streaming.isNotEmpty ? 1 : 0);

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: const Text('Assistant'),
            actions: [
              IconButton(
                tooltip: 'Language',
                icon: const Icon(Icons.translate),
                onPressed: () => _showLanguageSheet(context, assistant),
              ),
              IconButton(
                tooltip: 'AI diagnostics',
                icon: const Icon(Icons.speed_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AssistantDiagnosticsScreen(assistant: assistant),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Clear conversation',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: messages.isEmpty
                    ? null
                    : assistant.clearConversation,
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AssistantStatusBadge(
                    engineName: assistant.engineName,
                    riskLevel: riskLevel,
                    usesLlm: assistant.usesLlm,
                  ),
                ),
              ),
              if (!assistant.isReady) const _UnavailableNotice(),
              Expanded(
                child: itemCount == 0
                    ? _EmptyState(suggestions: _suggestions, onTap: _send)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          if (index < messages.length) {
                            return AssistantMessageBubble(
                              message: messages[index],
                            );
                          }
                          return AssistantMessageBubble(
                            message: AssistantMessage.assistant(streaming),
                            isStreaming: true,
                          );
                        },
                      ),
              ),
              if (assistant.isGenerating && streaming.isEmpty)
                const _TypingIndicator(),
              _Composer(
                controller: _controller,
                enabled: assistant.isReady && !assistant.isGenerating,
                onSend: () => _send(_controller.text),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showLanguageSheet(BuildContext context, AssistantService assistant) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF102833),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: AssistantLanguage.values
              .map(
                (language) => ListTile(
                  title: Text(language.nativeName),
                  subtitle: Text(language.englishName),
                  trailing: assistant.language == language
                      ? const Icon(Icons.check, color: Color(0xFF49D6C7))
                      : null,
                  onTap: () {
                    assistant.language = language;
                    Navigator.pop(sheetContext);
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1F26),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFFF7482).withValues(alpha: 0.5),
        ),
      ),
      child: const Text(
        'The assistant is starting up, or is unavailable on this device. '
        'Monitoring and alerts are unaffected.',
        style: TextStyle(color: Color(0xFFFFD9DE), height: 1.35),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.suggestions, required this.onTap});

  final List<String> suggestions;
  final Future<void> Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      children: [
        const Text(
          'Ask about your readings',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'Answers come from this phone. No internet needed.',
          style: TextStyle(color: Color(0xFFB8CED5)),
        ),
        const SizedBox(height: 18),
        ...suggestions.map(
          (suggestion) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
              ),
              onPressed: () => onTap(suggestion),
              child: Row(
                children: [
                  const Icon(
                    Icons.chat_bubble_outline,
                    size: 17,
                    color: Color(0xFF9CC9FF),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      suggestion,
                      style: const TextStyle(color: Color(0xFFE6F1F4)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text(
            'Thinking…',
            style: TextStyle(color: Color(0xFF91AAB5), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: enabled
                      ? 'Ask a question…'
                      : 'Assistant unavailable',
                  filled: true,
                  fillColor: const Color(0xFF102833),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
