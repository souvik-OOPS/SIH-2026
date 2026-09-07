import 'package:flutter/services.dart';
import '../core/monitoring/health_alert.dart';

class MonitoringStatus {
  const MonitoringStatus({
    this.requested = false,
    this.running = false,
    this.notificationsAllowed = false,
  });
  final bool requested, running, notificationsAllowed;
  factory MonitoringStatus.fromMap(Map<dynamic, dynamic>? map) =>
      MonitoringStatus(
        requested: map?['requested'] == true,
        running: map?['running'] == true,
        notificationsAllowed: map?['notificationsAllowed'] == true,
      );
}

class MonitoringGateway {
  MonitoringGateway({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('in.sih.swasthyashield/monitoring');
  final MethodChannel _channel;
  static const _permissions = MethodChannel(
    'in.sih.swasthyashield/ble_permissions',
  );
  void onStopped(Future<void> Function() callback) =>
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stopped') await callback();
      });
  Future<MonitoringStatus> status() async =>
      MonitoringStatus.fromMap(await _channel.invokeMapMethod('status'));
  Future<void> start() => _channel.invokeMethod('start');
  Future<void> stop() => _channel.invokeMethod('stop');
  Future<void> update(String text) =>
      _channel.invokeMethod('update', {'text': text});
  Future<bool> requestNotifications() async =>
      await _permissions.invokeMethod<bool>('requestNotificationPermission') ??
      false;
  Future<void> settings() => _channel.invokeMethod('settings');
  Future<bool> notify(HealthAlert alert) async =>
      await _channel.invokeMethod<bool>('alert', {
        'id':
            27000 +
            alert.type.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) % 10000),
        'title': '${alert.demo ? 'DEMO · ' : ''}${alert.title}',
        'body': alert.body,
      }) ??
      false;
}
