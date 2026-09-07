import 'package:flutter/material.dart';
import 'monitoring_controller.dart';

class MonitoringSettingsScreen extends StatelessWidget {
  const MonitoringSettingsScreen({
    super.key,
    required this.monitoring,
    required this.onStop,
    required this.onStart,
  });
  final MonitoringController monitoring;
  final Future<void> Function() onStop, onStart;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Monitoring & privacy')),
    body: AnimatedBuilder(
      animation: monitoring,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Background monitoring'),
            subtitle: const Text(
              'Connect your wearable and keep monitoring while using other apps or locking the screen.',
            ),
            value: monitoring.enabled,
            onChanged: (_) async {
              if (monitoring.enabled) {
                await onStop();
              } else {
                await onStart();
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text(
              monitoring.status.notificationsAllowed
                  ? 'Notifications enabled'
                  : 'Notifications disabled',
            ),
            subtitle: const Text(
              'Unusual heart rate, oxygen readings, falls, and missing data.',
            ),
            trailing: TextButton(
              onPressed: monitoring.enableNotifications,
              child: const Text('Manage'),
            ),
          ),
          if (monitoring.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                monitoring.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Divider(),
          const Text(
            'Alert rules',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Heart rate above 120 or below 50 bpm, or SpO2 below 92%: 30 seconds of usable readings. SpO2 at or below 88%: immediate alert. Repeated alerts of the same type are limited to once every 5 minutes. Poor contact and stale data do not trigger vital alarms. These are prototype defaults, not a diagnosis.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Android shows a persistent notification while monitoring. Its Stop action disconnects the wearable. Force-stopping the app or restarting the phone ends monitoring; reopen the app to resume. Bluetooth must stay enabled. Device battery restrictions can interrupt background work.',
          ),
          const Divider(height: 32),
          const Text(
            'Data on this phone',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Up to 7 days of sampled readings and 500 alerts are stored locally. Chat stays in memory and can be cleared in the assistant. No history is uploaded. Emergency contacts are managed on the Live screen; SMS requires cellular coverage.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete saved readings and alerts'),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete local history?'),
                  content: const Text(
                    'Saved readings and alerts will be removed. New readings will continue to be recorded while monitoring.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await monitoring.flushed;
                await monitoring.store.clear();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Local history deleted.')),
                  );
                }
              }
            },
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Demo notifications'),
            subtitle: const Text(
              'Allow clearly labelled test alerts from Replay. No SMS is sent.',
            ),
            value: monitoring.demoNotifications,
            onChanged: (value) async {
              if (value) {
                await monitoring.enableDemoNotifications();
              } else {
                monitoring.demoNotifications = false;
                await monitoring.refresh();
              }
            },
          ),
        ],
      ),
    ),
  );
}
