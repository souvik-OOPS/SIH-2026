import 'package:flutter/material.dart';

import '../models/assistant_context.dart';
import '../models/assistant_mode.dart';
import '../services/assistant_service.dart';
import '../widgets/assistant_message_bubble.dart';
import '../widgets/assistant_status_badge.dart';
import 'offline_ai_setup_screen.dart';

/// Chat surface for the offline assistant.
///
/// [contextProvider] is called per question so every answer is grounded in the
/// state at the moment it was asked, without the screen subscribing to the
/// telemetry stream itself.
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
    'Explain my current readings',
    'Why am I seeing this warning?',
    'Is the sensor connected?',
    'What does poor signal mean?',
    'Explain the latest alert',
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
    await widget.assistant.ask(question, context: widget.contextProvider());
    if (!mounted) return;
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
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
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: const Text('Assistant'),
            actions: [
              IconButton(
                tooltip: 'Offline AI setup',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OfflineAiSetupScreen(assistant: assistant),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Clear conversation',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: messages.isEmpty
                    ? null
                    : () => assistant.clearConversation(),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AssistantStatusBadge(mode: assistant.mode),
                ),
              ),
              if (assistant.mode == AssistantMode.unavailable)
                const _UnavailableNotice(),
              Expanded(
                child: messages.isEmpty
                    ? _EmptyState(suggestions: _suggestions, onTap: _send)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                        itemCount: messages.length,
                        itemBuilder: (context, index) =>
                            AssistantMessageBubble(message: messages[index]),
                      ),
              ),
              if (assistant.isGenerating) const _TypingIndicator(),
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
        'The assistant is not available on this device. Monitoring and alerts '
        'are unaffected.',
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
