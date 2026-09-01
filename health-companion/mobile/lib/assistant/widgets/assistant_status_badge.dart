import 'package:flutter/material.dart';

import '../models/assistant_mode.dart';

/// Tells the user which capability is answering, and that it works offline.
///
/// Shown always, not only on failure: a person reading a stored knowledge-base
/// answer should know it is not a generated one.
class AssistantStatusBadge extends StatelessWidget {
  const AssistantStatusBadge({super.key, required this.mode});

  final AssistantMode mode;

  @override
  Widget build(BuildContext context) {
    final colour = switch (mode) {
      AssistantMode.builtIn => const Color(0xFF49D6C7),
      AssistantMode.downloadedModel => const Color(0xFF9CC9FF),
      AssistantMode.localKnowledgeOnly => const Color(0xFFF6C859),
      AssistantMode.unavailable => const Color(0xFFFF7482),
    };

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Pill(label: mode.label.toUpperCase(), colour: colour),
        if (mode.worksOffline)
          const _Pill(label: 'OFFLINE', colour: Color(0xFF9FDDC5)),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.colour});

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: colour,
        ),
      ),
    );
  }
}
