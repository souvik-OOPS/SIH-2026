import 'dart:async';

import 'package:flutter/material.dart';

import 'assistant/models/assistant_context.dart';
import 'assistant/services/assistant_context_builder.dart';
import 'assistant/services/assistant_service.dart';
import 'core/escalation/escalation_service.dart';
import 'features/monitoring/dashboard_screen.dart';
import 'features/monitoring/telemetry_session.dart';
import 'services/android_sms_gateway.dart';
import 'services/ble_telemetry_source.dart';
import 'services/contact_store.dart';
import 'services/replay_telemetry_source.dart';

class SwasthyaShieldApp extends StatefulWidget {
  const SwasthyaShieldApp({
    super.key,
    required this.session,
    required this.escalation,
    required this.contactStore,
    required this.assistant,
  });

  final TelemetrySession session;
  final EscalationService escalation;
  final ContactStore contactStore;
  final AssistantService assistant;

  factory SwasthyaShieldApp.replay() {
    final source = ReplayTelemetrySource();
    return SwasthyaShieldApp(
      session: TelemetrySession(source: source, demoControls: source),
      escalation: EscalationService(gateway: AndroidSmsGateway()),
      contactStore: ContactStore(),
      assistant: AssistantService(),
    );
  }

  @override
  State<SwasthyaShieldApp> createState() => _SwasthyaShieldAppState();
}

class _SwasthyaShieldAppState extends State<SwasthyaShieldApp> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.session.start());
    unawaited(_loadContacts());
    // Optional layer: a failure here must not affect monitoring.
    unawaited(widget.assistant.initialize());
  }

  Future<void> _loadContacts() async {
    final contacts = await widget.contactStore.load();
    if (!mounted) return;
    widget.escalation.loadContacts(contacts);
  }

  Future<void> _persistContacts() =>
      widget.contactStore.save(widget.escalation.contacts);

  static const _contextBuilder = AssistantContextBuilder();

  /// Builds the assistant's view of the app at the moment a question is
  /// asked. `safety:` stays null until the Day 4-6 risk engine exists, so
  /// the assistant reports riskLevel as not computed rather than guessing.
  AssistantContext _assistantContext() => _contextBuilder.build(
    frame: widget.session.latestFrame,
    signalTier: widget.session.signalTier,
    connectivity: widget.session.connectivity,
    isStale: widget.session.isStale,
  );

  @override
  void dispose() {
    widget.session.dispose();
    super.dispose();
  }

  Future<void> _connectLiveBle() async {
    await widget.session.replaceSource(BleTelemetrySource());
  }

  Future<void> _returnToReplay() async {
    final source = ReplayTelemetrySource();
    await widget.session.replaceSource(source, demoControls: source);
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF081923);
    return MaterialApp(
      title: 'SwasthyaShield Edge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF49D6C7),
          brightness: Brightness.dark,
          surface: navy,
        ),
        scaffoldBackgroundColor: navy,
        useMaterial3: true,
      ),
      home: DashboardScreen(
        session: widget.session,
        escalation: widget.escalation,
        assistant: widget.assistant,
        assistantContext: _assistantContext,
        onContactsChanged: _persistContacts,
        onConnectLiveBle: _connectLiveBle,
        onReturnToReplay: _returnToReplay,
      ),
    );
  }
}
