import 'package:flutter/material.dart';

import '../models/assistant_message.dart';

class AssistantMessageBubble extends StatelessWidget {
  const AssistantMessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
  });

  final AssistantMessage message;

  /// True while tokens are still arriving, so the bubble can show a caret.
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final background = isUser
        ? const Color(0xFF1A4050)
        : message.isError
        ? const Color(0xFF3A1F26)
        : const Color(0xFF102833);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: Border.all(
            color: message.isError
                ? const Color(0xFFFF7482).withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.07),
          ),
        ),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isStreaming ? '${message.text}▌' : message.text,
              style: const TextStyle(height: 1.4, color: Color(0xFFE6F1F4)),
            ),
            // Stored text is labelled so it is never mistaken for generated
            // words.
            if (!isUser && !isStreaming && message.isStoredAnswer)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'From the offline guide',
                  style: TextStyle(fontSize: 10, color: Color(0xFF91AAB5)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
