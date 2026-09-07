import 'package:flutter/material.dart';

import '../../assistant/models/assistant_context.dart';
import '../../assistant/screens/assistant_screen.dart';
import '../../assistant/services/assistant_service.dart';
import '../../core/escalation/escalation_service.dart';
import '../../core/models/telemetry_frame.dart';
import '../../core/models/vital_history.dart';
import '../../core/theme/app_theme.dart';
import '../../core/safety/safety_assessment.dart';
import '../../core/telemetry/signal_quality.dart';
import '../../core/telemetry/telemetry_source.dart';
import '../escalation/emergency_contacts_sheet.dart';
import 'heart_rate_chart.dart';
import 'telemetry_session.dart';
import 'monitoring_controller.dart';
import 'emergency_summary_screen.dart';

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
    this.onToggleTheme,
    this.monitoring,
    this.activityBuilder,
    this.settingsBuilder,
  });

  final TelemetrySession session;
  final EscalationService escalation;
  final AssistantService assistant;
  final AssistantContext Function() assistantContext;
  final Future<void> Function() onContactsChanged;
  final Future<void> Function() onConnectLiveBle;
  final Future<void> Function() onReturnToReplay;

  /// Optional so the screen still builds anywhere it is used without one.
  final VoidCallback? onToggleTheme;
  final MonitoringController? monitoring;
  final WidgetBuilder? activityBuilder, settingsBuilder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([session, escalation, ?monitoring]),
      builder: (context, _) {
        final frame = session.latestFrame;
        final replayMode = session.supportsDemoControls;
        return Scaffold(
          bottomNavigationBar: NavigationBar(
            selectedIndex: 0,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                label: 'Live',
              ),
              NavigationDestination(
                icon: Icon(Icons.history),
                label: 'Activity',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                label: 'Assistant',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: 'Settings',
              ),
            ],
            onDestinationSelected: (index) {
              final WidgetBuilder? builder = switch (index) {
                1 => activityBuilder,
                2 => (_) => AssistantScreen(
                  assistant: assistant,
                  contextProvider: assistantContext,
                  stateListenable: session,
                ),
                3 => settingsBuilder,
                _ => null,
              };
              if (builder != null) {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: builder));
              }
            },
          ),
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
              if (onToggleTheme != null)
                IconButton(
                  tooltip: 'Light / dark',
                  icon: Icon(
                    Theme.of(context).brightness == Brightness.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                  ),
                  onPressed: onToggleTheme,
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
                    monitoring: monitoring,
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
/// The learned model's opinion, shown as a second opinion beside the rules.
///
/// Deliberately worded as similarity, not diagnosis. The autoencoder was
/// trained only on healthy resting physiology and has no labels for named
/// conditions, so the honest claim is "this window is unlike the normal it was
/// shown" — never what is wrong with the wearer. It also never overrides the
/// risk verdict above it; the rules are the floor and this sits on top.
class _AnomalyCard extends StatelessWidget {
  const _AnomalyCard({required this.session});

  final TelemetrySession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signals = theme.extension<SignalColors>();
    final score = session.anomalyScore;
    final ready = session.anomalyModelReady;
    final progress = session.anomalyWindowProgress;

    final String headline;
    final String detail;
    final Color tone;

    if (!ready) {
      headline = 'Model unavailable';
      detail = 'Monitoring continues on the safety rules alone.';
      tone = theme.colorScheme.onSurfaceVariant;
    } else if (score == null) {
      headline = 'Gathering baseline';
      detail = progress <= 0
          ? 'Waiting for a steady pulse reading.'
          : '${(progress * 100).round()}% of the 30-second window collected.';
      tone = theme.colorScheme.onSurfaceVariant;
    } else if (score.ratio >= 1.6) {
      headline = 'Unlike your normal';
      detail =
          'Pattern is ${score.ratio.toStringAsFixed(1)}x past the learned '
          'threshold. This is a similarity score, not a diagnosis.';
      tone = signals?.forRisk(RiskLevel.warning) ?? theme.colorScheme.error;
    } else if (score.anomalous) {
      headline = 'Slightly unusual';
      detail =
          'Pattern is ${score.ratio.toStringAsFixed(1)}x the learned '
          'threshold. Watching for now.';
      tone = signals?.forRisk(RiskLevel.watch) ?? theme.colorScheme.tertiary;
    } else {
      headline = 'Looks normal';
      detail =
          'Pattern matches your learned baseline '
          '(${(score.ratio * 100).round()}% of threshold).';
      tone = signals?.forRisk(RiskLevel.normal) ?? theme.colorScheme.primary;
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.psychology_outlined, color: tone, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  headline,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'OFFLINE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (score != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: LinearProgressIndicator(
                minHeight: 9,
                value: (score.ratio / 3).clamp(0.0, 1.0),
                color: tone,
                backgroundColor: const Color(0xFF23434D),
              ),
            ),
          ] else if (ready && progress > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: LinearProgressIndicator(
                minHeight: 9,
                value: progress,
                color: theme.colorScheme.onSurfaceVariant,
                backgroundColor: const Color(0xFF23434D),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
    this.monitoring,
  });

  final TelemetrySession session;
  final TelemetryFrame frame;
  final EscalationService escalation;
  final VoidCallback onManageContacts;
  final MonitoringController? monitoring;

  @override
  Widget build(BuildContext context) {
    final assessment = session.signalAssessment;
    final safety = session.safetyAssessment;
    final trust = safety?.sensorTrust;
    final fresh =
        session.isRunning &&
        !session.isStale &&
        session.connectivity == TelemetryConnectivity.connected;
    final usablePulse = fresh && (trust?.canUsePhysiology ?? false);
    final signalColour = trust == null
        ? _signalQualityColour(assessment.level)
        : _sensorTrustColour(trust.state);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        if (monitoring != null && !session.supportsDemoControls)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              monitoring!.error ??
                  (monitoring!.enabled
                      ? (monitoring!.status.notificationsAllowed
                            ? 'Background monitoring on · alerts enabled'
                            : 'Background monitoring on · enable notifications in Settings')
                      : 'Monitoring stopped · reconnect to resume'),
              style: TextStyle(
                color:
                    monitoring!.error != null ||
                        !monitoring!.status.notificationsAllowed
                    ? const Color(0xFFF6C859)
                    : const Color(0xFF49D6C7),
              ),
            ),
          ),
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
        _RiskCard(assessment: safety),
        if (safety?.fallState == FallWorkflowState.checkIn)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.icon(
              onPressed: session.confirmOkay,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text("I'M OK — dismiss fall check-in"),
            ),
          ),
        const SizedBox(height: 20),
        Text('LIVE VITALS', style: _sectionStyle),
        const SizedBox(height: 10),
        _HeroVital(
          label: 'HEART RATE',
          value: usablePulse
              ? frame.heartRateBpm?.toStringAsFixed(0) ?? '—'
              : '—',
          unit: 'BPM',
          trend: session.heartRateHistory,
          trendColour: signalColour,
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.92,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          children: [
            _VitalTile(
              icon: Icons.water_drop_outlined,
              label: 'SpO₂',
              value: usablePulse
                  ? frame.spo2Percent?.toStringAsFixed(0) ?? '—'
                  : '—',
              unit: '%',
            ),
            _VitalTile(
              icon: Icons.device_thermostat_outlined,
              label: 'AIR TEMP',
              value: fresh
                  ? frame.ambientTemperatureC?.toStringAsFixed(1) ?? '—'
                  : '—',
              unit: '°C',
            ),
            _VitalTile(
              icon: Icons.opacity_outlined,
              label: 'HUMIDITY',
              value: fresh
                  ? frame.humidityPercent?.toStringAsFixed(0) ?? '—'
                  : '—',
              unit: '%',
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text('SENSOR STATUS', style: _sectionStyle),
        const SizedBox(height: 10),
        _SensorStatusCard(
          frame: frame,
          signalColour: signalColour,
          assessment: assessment,
          trust: trust,
        ),
        const SizedBox(height: 22),
        Text('ON-DEVICE AI', style: _sectionStyle),
        const SizedBox(height: 10),
        _AnomalyCard(session: session),
        const SizedBox(height: 22),
        Text('EMERGENCY', style: _sectionStyle),
        const SizedBox(height: 10),
        if (monitoring != null) ...[
          OutlinedButton.icon(
            icon: const Icon(Icons.summarize_outlined),
            label: const Text('Preview emergency summary'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => EmergencySummaryScreen(monitoring: monitoring!),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        _SosCard(
          escalation: escalation,
          frame: frame,
          onManageContacts: onManageContacts,
        ),
        const SizedBox(height: 22),
        Text('EVENTS & ALERTS', style: _sectionStyle),
        const SizedBox(height: 10),
        _EventCard(frame: frame, assessment: safety),
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

class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.assessment});

  final SafetyAssessment? assessment;

  @override
  Widget build(BuildContext context) {
    final safety = assessment;
    if (safety != null) {
      final colour = _riskColour(safety.riskLevel);
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF102833),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colour.withValues(alpha: 0.55)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, size: 42, color: colour),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('PERSONAL RISK', style: _sectionStyle),
                  const SizedBox(height: 3),
                  Text(
                    'RISK ${safety.score} - ${safety.riskLevel.wireValue}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: colour,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${safety.sensorTrust.state.label} SENSOR TRUST - ${safety.sensorTrust.score}%',
                    style: const TextStyle(color: Color(0xFFC2D7DA)),
                  ),
                  if (safety.explanations.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...safety.explanations
                        .take(4)
                        .map(
                          (reason) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '- ${reason.detail}',
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.25,
                                color: Color(0xFFB8CED5),
                              ),
                            ),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }
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

/// The lead vital, sized to be read from across a room.
///
/// [FittedBox] rather than a fixed size: a three-digit rate at text scale 1.3
/// would otherwise overflow, and a clipped heart rate on stage is worse than a
/// slightly smaller one.
class _HeroVital extends StatelessWidget {
  const _HeroVital({
    required this.label,
    required this.value,
    required this.unit,
    this.trend,
    this.trendColour,
  });

  final String label;
  final String value;
  final String unit;

  /// Optional trend drawn beneath the number. A single instantaneous value
  /// says nothing about direction, which is most of what a reader wants from a
  /// vital sign — whether it is climbing, settling, or holding steady.
  final VitalHistory? trend;
  final Color? trendColour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: theme.textTheme.displayLarge),
                const SizedBox(width: 8),
                Text(
                  unit,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.textTheme.labelLarge?.color,
                  ),
                ),
              ],
            ),
          ),
          if (trend != null) ...[
            const SizedBox(height: 6),
            HeartRateChart(
              history: trend!,
              colour: trendColour ?? theme.colorScheme.primary,
            ),
          ],
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
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.signal.neutral),
          const Spacer(),
          Text(label, style: theme.textTheme.labelSmall, maxLines: 1),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: theme.textTheme.headlineMedium),
                const SizedBox(width: 3),
                Text(unit, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Color _signalQualityColour(SignalQualityLevel level) => switch (level) {
  SignalQualityLevel.excellent => const Color(0xFF49D6C7),
  SignalQualityLevel.good => const Color(0xFF7FC8FF),
  SignalQualityLevel.fair => const Color(0xFFF6C859),
  SignalQualityLevel.poor => const Color(0xFFFF7482),
  SignalQualityLevel.invalid => const Color(0xFF9CC9FF),
};

Color _sensorTrustColour(SensorTrustState state) => switch (state) {
  SensorTrustState.reliable => const Color(0xFF49D6C7),
  SensorTrustState.degraded => const Color(0xFFF6C859),
  SensorTrustState.reacquiring => const Color(0xFFFF7482),
  SensorTrustState.stale => const Color(0xFF9CC9FF),
};

Color _riskColour(RiskLevel level) => switch (level) {
  RiskLevel.notComputed => const Color(0xFF91AAB5),
  RiskLevel.normal => const Color(0xFF49D6C7),
  RiskLevel.watch => const Color(0xFFF6C859),
  RiskLevel.warning => const Color(0xFFFF9E6B),
  RiskLevel.critical => const Color(0xFFFF7482),
};

class _SensorStatusCard extends StatelessWidget {
  const _SensorStatusCard({
    required this.frame,
    required this.signalColour,
    required this.assessment,
    required this.trust,
  });

  final TelemetryFrame frame;
  final Color signalColour;
  final SignalQualityAssessment assessment;
  final SensorTrustAssessment? trust;

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
                  // Say what the wearer is doing, not what the accelerometer
                  // measured. A raw figure in g is not readable at a glance and
                  // never falls to zero anyway, since gravity is always present.
                  'Motion  ${frame.activityLabel ?? '--'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              // The pulse sensor's contact state used to be printed here. It
              // describes the finger on the MAX30102, not the IMU, so on the
              // motion row it captioned one sensor's reading with another
              // sensor's status - "No finger contact" next to a movement level
              // that has nothing to do with a finger. It still appears under
              // Signal confidence below, which is what it actually qualifies.
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
                trust?.state.label ?? assessment.level.label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: signalColour,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${trust?.score ?? (frame.signalQuality * 100).round()}%',
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
              value:
                  trust?.state == SensorTrustState.reacquiring ||
                      trust?.state == SensorTrustState.stale ||
                      assessment.level == SignalQualityLevel.invalid
                  ? null
                  : (trust?.score ?? (frame.signalQuality * 100)) / 100,
              color: signalColour,
              backgroundColor: const Color(0xFF23434D),
            ),
          ),
          if (trust != null && trust!.reasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                trust!.reasons.first,
                style: const TextStyle(color: Color(0xFFB8CED5), fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.frame, required this.assessment});

  final TelemetryFrame frame;
  final SafetyAssessment? assessment;

  @override
  Widget build(BuildContext context) {
    final safety = assessment;
    if (safety != null) {
      final message = frame.sosPressed
          ? 'Replay SOS input received.'
          : switch (safety.fallState) {
              FallWorkflowState.checkIn =>
                'Possible fall detected. Fall check-in is active.',
              FallWorkflowState.escalated =>
                'Possible fall check-in expired without a response.',
              FallWorkflowState.monitoring =>
                safety.sensorTrust.state == SensorTrustState.reacquiring
                    ? 'Reading unreliable - reacquiring.'
                    : 'No active fall workflow.',
            };
      return Container(
        padding: const EdgeInsets.all(17),
        decoration: _cardDecoration,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              safety.fallDetected
                  ? Icons.personal_injury_outlined
                  : Icons.info_outline,
              color: safety.fallDetected
                  ? const Color(0xFFFF7482)
                  : const Color(0xFFF6C859),
            ),
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
    final message = frame.sosPressed
        ? 'SOS input received. Open emergency contacts to request help.'
        : 'Waiting for a risk assessment from the incoming readings.';
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
