import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/monitoring/health_alert_engine.dart';
import '../../core/models/telemetry_frame.dart';
import '../../services/monitoring_gateway.dart';
import '../../services/monitoring_store.dart';
import 'telemetry_session.dart';

/// App-owned coordinator, independent of which screen is visible.
class MonitoringController extends ChangeNotifier {
  MonitoringController(
    this.session, {
    MonitoringGateway? gateway,
    MonitoringStore? store,
  }) : gateway = gateway ?? MonitoringGateway(),
       store = store ?? MonitoringStore();
  final TelemetrySession session;
  final MonitoringGateway gateway;
  final MonitoringStore store;
  final HealthAlertEngine _alerts = HealthAlertEngine();
  MonitoringStatus status = const MonitoringStatus();
  String? error;
  bool enabled = false;
  bool demoNotifications = false;
  DateTime? _lastStatus, _lastSaved;
  Future<void> _writes = Future.value();
  Timer? _timer;
  Future<void> get flushed => _writes;

  Future<bool> initialize(Future<void> Function() stopped) async {
    gateway.onStopped(() async {
      enabled = false;
      status = const MonitoringStatus();
      await stopped();
      notifyListeners();
    });
    try {
      status = await gateway.status();
      enabled = status.requested;
    } on Object catch (e) {
      error = 'Background service unavailable: $e';
    }
    session.addListener(_onSession);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _onSession());
    return enabled;
  }

  Future<void> start() async {
    await gateway.start();
    enabled = true;
    _alerts.reset();
    error = null;
    await refresh();
  }

  Future<void> stop() async {
    enabled = false;
    _alerts.reset();
    await gateway.stop();
    await refresh();
  }

  Future<void> refresh() async {
    try {
      status = await gateway.status();
    } on Object catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> enableNotifications() async {
    try {
      await gateway.requestNotifications();
      await refresh();
      if (!status.notificationsAllowed) await gateway.settings();
    } on Object catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  Future<void> enableDemoNotifications() async {
    await enableNotifications();
    demoNotifications = true;
    _alerts.reset();
    notifyListeners();
  }

  void _enqueue(Future<void> Function() action) {
    _writes = _writes.then((_) => action()).catchError((Object e) {
      error = 'Could not save or notify: $e';
      notifyListeners();
    });
  }

  void _onSession() {
    if (!session.isRunning) return;
    final frame = session.latestFrame;
    if (frame == null) return;
    final demo = session.supportsDemoControls;
    final now = DateTime.now();
    if (_lastSaved == null ||
        now.difference(_lastSaved!) >= const Duration(seconds: 10)) {
      _lastSaved = now;
      final trustworthy =
          !session.isStale &&
          session.connectivity == TelemetryConnectivity.connected &&
          (session.safetyAssessment?.sensorTrust.canUsePhysiology ?? false);
      final row = <String, Object?>{
        'at': now.millisecondsSinceEpoch,
        'hr': trustworthy ? frame.heartRateBpm : null,
        'o2': trustworthy ? frame.spo2Percent : null,
        'temperature':
            session.isStale ||
                session.connectivity != TelemetryConnectivity.connected
            ? null
            : frame.ambientTemperatureC,
        'humidity':
            session.isStale ||
                session.connectivity != TelemetryConnectivity.connected
            ? null
            : frame.humidityPercent,
        'risk': session.safetyAssessment?.riskLevel.name,
        'trusted': trustworthy ? 1 : 0,
        'demo': demo ? 1 : 0,
      };
      _enqueue(() => store.record(row));
    }
    if (enabled &&
        !demo &&
        (_lastStatus == null ||
            now.difference(_lastStatus!) >= const Duration(seconds: 15))) {
      _lastStatus = now;
      final message = session.isStale
          ? 'Waiting for fresh sensor readings'
          : session.connectivity == TelemetryConnectivity.connected
          ? 'Wearable connected · monitoring locally'
          : 'Wearable disconnected · reconnecting';
      unawaited(
        gateway.update(message).catchError((Object e) {
          error = '$e';
          notifyListeners();
        }),
      );
    }
    for (final alert in _alerts.assess(
      frame: frame,
      safety: session.safetyAssessment,
      stale: session.isStale,
      connectivity: session.connectivity,
      now: now,
    )) {
      _enqueue(() async {
        await store.addAlert(alert);
        if ((!demo && enabled) || (demo && demoNotifications)) {
          final posted = await gateway.notify(alert);
          if (!posted) {
            error = 'Notifications are disabled. Alerts are saved in Activity.';
            notifyListeners();
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    session.removeListener(_onSession);
    super.dispose();
  }
}
