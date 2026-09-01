import 'package:flutter/material.dart';

import '../../assistant/models/assistant_context.dart';
import '../../assistant/screens/assistant_screen.dart';
import '../../assistant/services/assistant_service.dart';
import '../../core/escalation/escalation_service.dart';
import '../../core/models/telemetry_frame.dart';
import '../../core/telemetry/signal_quality.dart';
import '../../core/telemetry/telemetry_source.dart';
import '../escalation/emergency_contacts_sheet.dart';
import 'telemetry_session.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.session,
    required this.escalation,
    required this.assistant,
    required this.assistantContext,
    required this.onContactsChanged,
    required this.onConnectLiveBle,
    required this.onReturnToReplay,
  });

  final TelemetrySession session;
  final EscalationService escalation;
  final AssistantService assistant;
  final AssistantContext Function() assistantContext;
  final Future<void> Function() onContactsChanged;
  final Future<void> Function() onConnectLiveBle;
  final Future<void> Function() onReturnToReplay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([session, escalation]),
      builder: (context, _) {
        final frame = session.latestFrame;
        final replayMode = session.supportsDemoControls;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            titleSpacing: 24,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SwasthyaShield',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  replayMode ? 'EDGE • REPLAY' : 'EDGE • LIVE BLE',
                  style: TextStyle(fontSize: 10, letterSpacing: 1.1),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Assistant',
                icon: const Icon(Icons.chat_bubble_outline),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AssistantScreen(
                      assistant: assistant,
                      contextProvider: assistantContext,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Developer settings',
                icon: const Icon(Icons.developer_mode_outlined),
                onPressed: () => _showScenarioSheet(context, session),
              ),
              IconButton(
                tooltip: replayMode
                    ? 'Connect live BLE device'
                    : 'Return to replay',
                icon: Icon(
                  replayMode
                      ? Icons.bluetooth_searching
                      : Icons.replay_outlined,
                ),
                onPressed: replayMode
                    ? () => onConnectLiveBle()
                    : () => onReturnToReplay(),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: frame == null
                ? _LoadingState(
                    error: session.error,
                    waitingForBle: !replayMode,
                  )
                : _DashboardBody(
                    session: session,
                    frame: frame,
                    escalation: escalation,
                    onManageContacts: () => _showContactsSheet(context),
                  ),
          ),
        );
      },
    );
  }

  void _showScenarioSheet(BuildContext context, TelemetrySession session) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF102833),
      builder: (sheetContext) => _ScenarioSheet(
        session: session,
        onScenarioSelected: (scenario) async {
          await session.switchScenario(scenario);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
        },
        onSelectLiveBle: () async {
          Navigator.pop(sheetContext);
          await onConnectLiveBle();
        },
        onSelectReplay: () async {
          Navigator.pop(sheetContext);
          await onReturnToReplay();
        },
      ),
    );
  }

  void _showContactsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF102833),
      builder: (sheetContext) => EmergencyContactsSheet(
        escalation: escalation,
        onChanged: onContactsChanged,
      ),
    );
  }
}

/// Manual SOS. Always confirms first: an accidental tap must not page the
/// wearer's family, and the confirmation doubles as a preview of exactly what
/// will be transmitted and to whom.
class _SosCard extends StatelessWidget {
  const _SosCard({
    required this.escalation,
    required this.frame,
    required this.onManageContacts,
  });

  final EscalationService escalation;
  final TelemetryFrame frame;
  final VoidCallback onManageContacts;

  @override
  Widget build(BuildContext context) {
    final contacts = escalation.contacts;
    final plural = contacts.length == 1 ? '' : 's';
    final subtitle = contacts.isEmpty
        ? 'No emergency contacts yet - add one to enable SOS.'
        : escalation.dryRun
        ? 'Rehearsal mode: ${contacts.length} contact$plural, nothing is transmitted.'
        : 'Sends SMS to ${contacts.length} contact$plural - works with no internet.';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFC2D7DA),
                    height: 1.35,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Emergency contacts',
                onPressed: onManageContacts,
                icon: const Icon(
                  Icons.group_outlined,
                  color: Color(0xFF9CC9FF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFC2384A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: contacts.isEmpty
                  ? null
                  : () => _confirmAndSend(context),
              icon: const Icon(Icons.sos_outlined),
              label: Text(
                escalation.dryRun ? 'SEND TEST SOS' : 'SEND SOS',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndSend(BuildContext context) async {
    const reason = 'Manual SOS from the wearer';
    final preview = escalation.composeMessage(reason: reason, frame: frame);
    final recipients = escalation.contacts
        .map((contact) => '${contact.name} (${contact.phone})')
        .join('\n');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF102833),
        title: Text(escalation.dryRun ? 'Send test SOS?' : 'Send SOS now?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('To:', style: TextStyle(fontWeight: FontWeight.w700)),
              Text(recipients),
              const SizedBox(height: 14),
              const Text(
                'Message:',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1E27),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  preview,
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
              if (escalation.dryRun)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Rehearsal mode is on - no SMS will actually be sent.',
                    style: TextStyle(color: Color(0xFFF6C859), fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC2384A),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final report = await escalation.escalate(reason: reason, frame: frame);
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF102833),
        title: const Text('Escalation result'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: report.results
                .map(
                  (result) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${result.contact.name} - ${_outcomeLabel(result.outcome)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _outcomeColour(result.outcome),
                          ),
                        ),
                        Text(
                          result.note,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB8CED5),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _outcomeLabel(EscalationOutcome outcome) => switch (outcome) {
    EscalationOutcome.sent => 'SENT',
    EscalationOutcome.simulated => 'REHEARSED',
    EscalationOutcome.heldByCooldown => 'HELD',
    EscalationOutcome.permissionDenied => 'BLOCKED',
    EscalationOutcome.failed => 'FAILED',
  };

  static Color _outcomeColour(EscalationOutcome outcome) => switch (outcome) {
    EscalationOutcome.sent => const Color(0xFF49D6C7),
    EscalationOutcome.simulated => const Color(0xFF9CC9FF),
    EscalationOutcome.heldByCooldown => const Color(0xFFF6C859),
    EscalationOutcome.permissionDenied => const Color(0xFFFF7482),
    EscalationOutcome.failed => const Color(0xFFFF7482),
  };
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({this.error, required this.waitingForBle});

  final Object? error;
  final bool waitingForBle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              error == null
                  ? waitingForBle
                        ? 'Scanning for SwasthyaShield Edge…'
                        : 'Loading deterministic replay telemetry…'
                  : 'Telemetry source could not start: $error',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({
    required this.session,
    required this.frame,
    required this.escalation,
    required this.onManageContacts,
  });

  final TelemetrySession session;
  final TelemetryFrame frame;
  final EscalationService escalation;
  final VoidCallback onManageContacts;

  @override
  Widget build(BuildContext context) {
    final tier = session.signalTier;
    final signalColour = _tierColour(tier);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatusPill(
              label: session.connectivity.label.toUpperCase(),
              colour: session.connectivity == TelemetryConnectivity.connected
                  ? const Color(0xFF49D6C7)
                  : const Color(0xFFF6C859),
            ),
            _StatusPill(
              label: '${frame.sourceType.label.toUpperCase()} SOURCE',
              colour: const Color(0xFF9CC9FF),
            ),
            if (session.isStale)
              const _StatusPill(label: 'STALE DATA', colour: Color(0xFFF6C859)),
            const _StatusPill(
              label: 'OFFLINE-READY',
              colour: Color(0xFF9FDDC5),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            _timeLabel(frame.timestamp),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.56),
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 18),
        const _RiskPlaceholderCard(),
        const SizedBox(height: 20),
        Text('LIVE VITALS', style: _sectionStyle),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.5,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          children: [
            _VitalTile(
              icon: Icons.favorite_outline,
              label: 'HEART RATE',
              value: frame.heartRateBpm?.toStringAsFixed(0) ?? '—',
              unit: 'BPM',
              accent: const Color(0xFFFF7482),
            ),
            _VitalTile(
              icon: Icons.water_drop_outlined,
              label: 'SpO₂',
              value: frame.spo2Percent?.toStringAsFixed(0) ?? '—',
              unit: '%',
              accent: const Color(0xFF7FC8FF),
            ),
            _VitalTile(
              icon: Icons.device_thermostat_outlined,
              label: 'AMBIENT TEMP',
              value: frame.ambientTemperatureC?.toStringAsFixed(1) ?? '--',
              unit: '°C',
              accent: const Color(0xFFF6C859),
            ),
            _VitalTile(
              icon: Icons.opacity_outlined,
              label: 'HUMIDITY',
              value: frame.humidityPercent?.toStringAsFixed(0) ?? '--',
              unit: '%',
              accent: const Color(0xFF9FDDC5),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text('SENSOR STATUS', style: _sectionStyle),
        const SizedBox(height: 10),
        _SensorStatusCard(frame: frame, signalColour: signalColour, tier: tier),
        const SizedBox(height: 22),
        Text('EMERGENCY', style: _sectionStyle),
        const SizedBox(height: 10),
        _SosCard(
          escalation: escalation,
          frame: frame,
          onManageContacts: onManageContacts,
        ),
        const SizedBox(height: 22),
        Text('EVENTS & ALERTS', style: _sectionStyle),
        const SizedBox(height: 10),
        _EventPlaceholder(frame: frame),
      ],
    );
  }
}

const _sectionStyle = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.2,
  color: Color(0xFF91AAB5),
);

class _RiskPlaceholderCard extends StatelessWidget {
  const _RiskPlaceholderCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A4050), Color(0xFF12303B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF4B9D9A).withValues(alpha: 0.55),
        ),
      ),
      child: const Row(
        children: [
          Icon(Icons.shield_outlined, size: 42, color: Color(0xFF49D6C7)),
          SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PERSONAL RISK', style: _sectionStyle),
                SizedBox(height: 3),
                Text(
                  'Awaiting Day 4–6 engine',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 3),
                Text(
                  'Replay telemetry is flowing locally.',
                  style: TextStyle(color: Color(0xFFC2D7DA)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VitalTile extends StatelessWidget {
  const _VitalTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF102833),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: accent),
          const Spacer(),
          Text(label, style: _sectionStyle.copyWith(fontSize: 9)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  unit,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF91AAB5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Color _tierColour(SignalTier tier) => switch (tier) {
  SignalTier.good => const Color(0xFF49D6C7),
  SignalTier.fair => const Color(0xFFF6C859),
  SignalTier.poor => const Color(0xFFFF7482),
  SignalTier.reacquiring => const Color(0xFF9CC9FF),
};

class _SensorStatusCard extends StatelessWidget {
  const _SensorStatusCard({
    required this.frame,
    required this.signalColour,
    required this.tier,
  });

  final TelemetryFrame frame;
  final Color signalColour;
  final SignalTier tier;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration,
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.sensors_outlined, color: Color(0xFF9CC9FF)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Motion ${frame.accelerometerMagnitude?.toStringAsFixed(2) ?? '--'} g',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                frame.contactState.label,
                style: const TextStyle(color: Color(0xFFB8CED5), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Text(
                'Signal confidence',
                style: TextStyle(color: Color(0xFFB8CED5)),
              ),
              const Spacer(),
              Text(
                tier.label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: signalColour,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(frame.signalQuality * 100).round()}%',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: signalColour,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: LinearProgressIndicator(
              minHeight: 9,
              value: tier == SignalTier.reacquiring
                  ? null
                  : frame.signalQuality,
              color: signalColour,
              backgroundColor: const Color(0xFF23434D),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventPlaceholder extends StatelessWidget {
  const _EventPlaceholder({required this.frame});

  final TelemetryFrame frame;

  @override
  Widget build(BuildContext context) {
    final message = frame.sosPressed
        ? 'Replay SOS input received — escalation is scheduled for Day 8.'
        : 'No risk rules enabled in Day 1. Replay packets are being received.';
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: _cardDecoration,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: Color(0xFFF6C859)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(height: 1.35, color: Color(0xFFC2D7DA)),
            ),
          ),
        ],
      ),
    );
  }
}

final _cardDecoration = BoxDecoration(
  color: const Color(0xFF102833),
  borderRadius: BorderRadius.circular(18),
  border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
);

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.colour});

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

class _ScenarioSheet extends StatelessWidget {
  const _ScenarioSheet({
    required this.session,
    required this.onScenarioSelected,
    required this.onSelectLiveBle,
    required this.onSelectReplay,
  });

  final TelemetrySession session;
  final Future<void> Function(ReplayScenario scenario) onScenarioSelected;
  final Future<void> Function() onSelectLiveBle;
  final Future<void> Function() onSelectReplay;

  @override
  Widget build(BuildContext context) {
    final replayMode = session.supportsDemoControls;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Developer settings',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Telemetry source',
                  style: TextStyle(color: Color(0xFFB8CED5)),
                ),
                const SizedBox(height: 6),
                _SourceOption(
                  label: 'Replay',
                  detail: 'Deterministic fixtures — no sensor required.',
                  icon: Icons.play_circle_outline,
                  selected: replayMode,
                  onTap: replayMode ? null : onSelectReplay,
                ),
                _SourceOption(
                  label: 'Live BLE',
                  detail: 'Connect to the SwasthyaShield-Edge wearable.',
                  icon: Icons.bluetooth_searching,
                  selected: !replayMode,
                  onTap: replayMode ? onSelectLiveBle : null,
                ),
                const Divider(height: 24),
                if (!replayMode)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Fixture controls apply to the replay source only.',
                      style: TextStyle(color: Color(0xFFB8CED5)),
                    ),
                  ),
                if (replayMode) ...[
                  const Text(
                    'Demo scenario',
                    style: TextStyle(color: Color(0xFFB8CED5)),
                  ),
                  const SizedBox(height: 6),
                  ...session.scenarios.map(
                    (scenario) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(scenario.label),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onScenarioSelected(scenario),
                    ),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Text('Playback speed'),
                      const Spacer(),
                      DropdownButton<double>(
                        value: session.playbackSpeed,
                        items: const [1.0, 2.0, 4.0]
                            .map(
                              (speed) => DropdownMenuItem(
                                value: speed,
                                child: Text('${speed.toInt()}×'),
                              ),
                            )
                            .toList(),
                        onChanged: (speed) {
                          if (speed != null) session.setPlaybackSpeed(speed);
                        },
                      ),
                      IconButton(
                        tooltip: 'Restart scenario',
                        onPressed: session.restart,
                        icon: const Icon(Icons.restart_alt),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.label,
    required this.detail,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final IconData icon;
  final bool selected;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF49D6C7);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: selected ? accent : null),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          color: selected ? accent : null,
        ),
      ),
      subtitle: Text(
        detail,
        style: const TextStyle(fontSize: 12, color: Color(0xFF91AAB5)),
      ),
      trailing: selected ? const Icon(Icons.check_circle, color: accent) : null,
      onTap: onTap == null ? null : () => onTap!(),
    );
  }
}

String _timeLabel(DateTime timestamp) {
  final local = timestamp.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}
