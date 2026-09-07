import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/monitoring/health_alert.dart';
import '../../core/monitoring/history_snapshot.dart';
import 'history_chart.dart';
import 'monitoring_controller.dart';
import 'emergency_summary_screen.dart';

typedef _ActivityData = ({
  HistorySnapshot history,
  List<HealthAlert> alerts,
  List<Map<String, Object?>> readings,
});

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.monitoring});
  final MonitoringController monitoring;
  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  late Future<_ActivityData> _data;
  late bool _demo;
  HistoryRange _range = HistoryRange.hour;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _demo = widget.monitoring.session.supportsDemoControls;
    _data = _load();
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<_ActivityData> _load() async {
    final demo = _demo, until = DateTime.now();
    final since = until.subtract(_range.duration);
    await widget.monitoring.flushed;
    final store = widget.monitoring.store;
    return (
      history: await store.history(since: since, until: until, demo: demo),
      alerts: await store.alerts(since: since, until: until, demo: demo),
      readings: await store.readings(since: since, until: until, demo: demo),
    );
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final next = _load();
    setState(() {
      _data = next;
    });
    // FutureBuilder displays the error; don't leak timer/pull-to-refresh failures.
    try {
      await next;
    } on Object {
      /* Rendered in the view. */
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Trends'),
            Tab(text: 'Alerts'),
            Tab(text: 'Readings'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Emergency summary',
            icon: const Icon(Icons.summarize_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    EmergencySummaryScreen(monitoring: widget.monitoring),
              ),
            ),
          ),
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('Wearable'),
                        icon: Icon(Icons.sensors),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('Demo'),
                        icon: Icon(Icons.science_outlined),
                      ),
                    ],
                    selected: {_demo},
                    onSelectionChanged: (values) {
                      _demo = values.single;
                      unawaited(_refresh());
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Wrap(
              spacing: 8,
              children: [
                for (final range in HistoryRange.values)
                  ChoiceChip(
                    label: Text(range.label),
                    selected: _range == range,
                    onSelected: (_) {
                      _range = range;
                      unawaited(_refresh());
                    },
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<_ActivityData>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Could not load local history: ${snapshot.error}',
                    ),
                  );
                }
                // Never display results from the previous source under the new source label.
                if (snapshot.connectionState != ConnectionState.done ||
                    snapshot.data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!;
                return TabBarView(
                  children: [
                    RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                            child: Text(
                              '${_demo ? 'DEMO data' : 'Wearable data'} · ${data.history.samples} saved samples · ${data.alerts.length} alerts\n'
                              'Tap a chart to inspect. Statistics use usable samples. Lines show interval averages and break at missing or unreliable data.',
                            ),
                          ),
                          for (final metric in HistoryMetric.values)
                            HistoryChart(history: data.history, metric: metric),
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'Sampled about every 10 seconds. Seven days stored on this phone.',
                            ),
                          ),
                        ],
                      ),
                    ),
                    RefreshIndicator(
                      onRefresh: _refresh,
                      child: data.alerts.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'No alerts for this source and period.',
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: data.alerts.length,
                              itemBuilder: (context, index) =>
                                  _alertCard(data.alerts[index]),
                            ),
                    ),
                    RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: data.readings.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                'Latest ${data.readings.length} samples in this period (up to 720). Unusable pulse readings are gaps.',
                              ),
                            );
                          }
                          final row = data.readings[index - 1];
                          String value(String key) =>
                              (row[key] as num?)?.toStringAsFixed(0) ?? '—';
                          return ListTile(
                            leading: Icon(
                              row['trusted'] == 1
                                  ? Icons.monitor_heart_outlined
                                  : Icons.sensors_off,
                            ),
                            title: Text(
                              'HR ${value('hr')} bpm · SpO2 ${value('o2')}%',
                            ),
                            subtitle: Text(
                              '${_time(DateTime.fromMillisecondsSinceEpoch(row['at'] as int))} · ${row['risk']}\n'
                              'Air ${value('temperature')} °C · humidity ${value('humidity')}%${_demo ? ' · DEMO' : ''}',
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _alertCard(HealthAlert alert) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: ListTile(
      leading: Icon(
        alert.acknowledged
            ? Icons.check_circle_outline
            : Icons.notifications_active_outlined,
        color: alert.critical ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text('${alert.demo ? 'DEMO · ' : ''}${alert.title}'),
      subtitle: Text(
        '${alert.body}\n${_time(alert.at)}${alert.acknowledged ? ' · Reviewed' : ''}',
      ),
      onTap: () async {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('${alert.demo ? 'DEMO · ' : ''}${alert.title}'),
            content: Text('${alert.body}\n\n${_time(alert.at)}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await widget.monitoring.store.acknowledge(alert.id);
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  } on Object {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text('Could not save review. Try again.'),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Mark reviewed'),
              ),
            ],
          ),
        );
        await _refresh();
      },
    ),
  );

  String _time(DateTime at) =>
      '${at.day}/${at.month} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
}
