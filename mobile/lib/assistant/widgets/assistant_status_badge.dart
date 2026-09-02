import 'package:flutter/material.dart';

import '../models/assistant_context.dart';

/// Shows which engine is answering, that it works offline, and the
/// RiskEngine's current state.
///
/// The risk pill reads from the app's own state, never from anything the
/// model said — that is the point of showing them side by side.
class AssistantStatusBadge extends StatelessWidget {
  const AssistantStatusBadge({
    super.key,
    required this.engineName,
    required this.riskLevel,
    this.usesLlm = false,
  });

  final String engineName;
  final RiskLevel riskLevel;
  final bool usesLlm;

  static Color riskColour(RiskLevel level) => switch (level) {
    RiskLevel.critical => const Color(0xFFFF7482),
    RiskLevel.warning => const Color(0xFFFF9E6B),
    RiskLevel.watch => const Color(0xFFF6C859),
    RiskLevel.normal => const Color(0xFF49D6C7),
    RiskLevel.notComputed => const Color(0xFF91AAB5),
  };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Pill(
          label: engineName.toUpperCase(),
          colour: usesLlm ? const Color(0xFF49D6C7) : const Color(0xFFF6C859),
        ),
        const _Pill(label: 'OFFLINE', colour: Color(0xFF9FDDC5)),
        _Pill(
          label: 'RISK: ${riskLevel.wireValue}',
          colour: riskColour(riskLevel),
        ),
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
