import 'dart:async';

import 'package:flutter/material.dart';

import 'assistant/models/assistant_context.dart';
import 'assistant/services/assistant_context_builder.dart';
import 'assistant/services/assistant_service.dart';
import 'core/escalation/escalation_service.dart';
import 'core/theme/app_theme.dart';
import 'features/monitoring/dashboard_screen.dart';
import 'features/monitoring/telemetry_session.dart';
import 'services/android_sms_gateway.dart';
import 'services/ble_telemetry_source.dart';
import 'services/contact_store.dart';
import 'services/replay_telemetry_source.dart';
import 'services/ble_permission_service.dart';
import 'features/monitoring/monitoring_controller.dart';
import 'features/monitoring/activity_screen.dart';
import 'features/monitoring/monitoring_settings_screen.dart';

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

class _SwasthyaShieldAppState extends State<SwasthyaShieldApp>
    with WidgetsBindingObserver {
  late final MonitoringController _monitoring;

  /// Dark is the demo default. Light is offered because a dark UI loses
  /// contrast punch on a projector in a lit room, where the black level rises
  /// and the whole image goes muddy.
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitoring = MonitoringController(widget.session);
    widget.assistant.liveContextProvider = _assistantContext;
    unawaited(_restoreMonitoring());
    // Optional layer, same contract as the assistant: the learned model is a
    // second opinion, and a missing or unreadable asset must leave the rule
    // engine monitoring exactly as before.
    unawaited(widget.session.loadModel());
    unawaited(_loadContacts());
    // Optional layer: a failure here must not affect monitoring.
    unawaited(widget.assistant.initialize());
  }

  Future<void> _restoreMonitoring() async {
    final restore = await _monitoring.initialize(() => widget.session.stop());
    if (restore) {
      if (!_monitoring.status.running) {
        try {
          await _monitoring.start();
        } on Object {
          _monitoring.error =
              'Reconnect from the Live screen to resume background monitoring.';
          await _monitoring.refresh();
          return;
        }
      }
      await widget.session.replaceSource(
        BleTelemetrySource(permissionsAlreadyGranted: true),
      );
    } else {
      await widget.session.start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_monitoring.refresh());
  }

  Future<void> _loadContacts() async {
    final contacts = await widget.contactStore.load();
    if (!mounted) return;
    widget.escalation.loadContacts(contacts);
  }

  Future<void> _persistContacts() =>
      widget.contactStore.save(widget.escalation.contacts);

  static const _contextBuilder = AssistantContextBuilder();

  /// Builds the assistant's view from the same immutable assessment the
  /// dashboard uses. The assistant receives no authority to alter it.
  AssistantContext _assistantContext() => _contextBuilder.build(
    frame: widget.session.latestFrame,
    signalTier: widget.session.signalAssessment.level,
    connectivity: widget.session.connectivity,
    isStale: widget.session.isStale,
    safety: widget.session.safetyAssessment,
    receivedAt: widget.session.lastFrameAt,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _monitoring.dispose();
    widget.assistant.dispose();
    widget.session.dispose();
    super.dispose();
  }

  Future<void> _connectLiveBle() async {
    try {
      if (!await BlePermissionService().requestScanAndConnect()) return;
      await _monitoring.gateway.requestNotifications();
      await _monitoring.start();
      await widget.session.replaceSource(
        BleTelemetrySource(permissionsAlreadyGranted: true),
      );
    } on Object catch (error) {
      _monitoring.error = 'Could not start monitoring: $error';
      await _monitoring.refresh();
    }
  }

  Future<void> _returnToReplay() async {
    await _monitoring.stop();
    final source = ReplayTelemetrySource();
    await widget.session.replaceSource(source, demoControls: source);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SwasthyaShield Edge',
      debugShowCheckedModeBanner: false,
      // Both themes carry the SignalColors extension and the projector type
      // ramp. Light exists because a dark UI loses contrast punch on a
      // projector in a lit room; dark stays the default for the demo.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      home: DashboardScreen(
        onToggleTheme: _toggleTheme,
        session: widget.session,
        escalation: widget.escalation,
        assistant: widget.assistant,
        assistantContext: _assistantContext,
        onContactsChanged: _persistContacts,
        onConnectLiveBle: _connectLiveBle,
        onReturnToReplay: _returnToReplay,
        monitoring: _monitoring,
        activityBuilder: (_) => ActivityScreen(monitoring: _monitoring),
        settingsBuilder: (_) => MonitoringSettingsScreen(
          monitoring: _monitoring,
          onStop: () async {
            await widget.session.stop();
            await _monitoring.stop();
          },
          onStart: _connectLiveBle,
        ),
      ),
    );
  }
}
