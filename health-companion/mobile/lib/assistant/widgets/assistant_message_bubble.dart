import 'package:flutter/material.dart';

import '../models/assistant_message.dart';
import '../models/assistant_mode.dart';

class AssistantMessageBubble extends StatelessWidget {
  const AssistantMessageBubble({super.key, required this.message});

  final AssistantMessage message;

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
              message.text,
              style: const TextStyle(height: 1.4, color: Color(0xFFE6F1F4)),
            ),
            // A stored answer is labelled so it is never mistaken for a
            // generated one.
            if (!isUser && message.mode == AssistantMode.localKnowledgeOnly)
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
