import 'package:flutter/material.dart';
import '../../core/escalation/emergency_summary.dart';
import '../../services/summary_share_gateway.dart';
import 'monitoring_controller.dart';

class EmergencySummaryScreen extends StatefulWidget {
  const EmergencySummaryScreen({super.key, required this.monitoring});
  final MonitoringController monitoring;
  @override
  State<EmergencySummaryScreen> createState() => _EmergencySummaryScreenState();
}

class _EmergencySummaryScreenState extends State<EmergencySummaryScreen> {
  late Future<EmergencySummary> _summary;
  bool _sharing = false;
  @override
  void initState() {
    super.initState();
    _summary = _capture();
  }

  Future<EmergencySummary> _capture() async {
    // Capture all live fields together before any database await.
    final session = widget.monitoring.session;
    final now = DateTime.now(), demo = session.supportsDemoControls;
    final frame = session.latestFrame, safety = session.safetyAssessment;
    final last = session.lastFrameAt, connectivity = session.connectivity;
    final running = session.isRunning, stale = session.isStale;
    final since = now.subtract(const Duration(minutes: 10));
    await widget.monitoring.flushed;
    final history = await widget.monitoring.store.history(
      since: since,
      until: now,
      demo: demo,
    );
    final alerts = await widget.monitoring.store.alerts(
      since: since,
      until: now,
      demo: demo,
    );
    return EmergencySummary.capture(
      now: now,
      demo: demo,
      frame: frame,
      safety: safety,
      lastReceivedAt: last,
      connectivity: connectivity,
      running: running,
      stale: stale,
      history: history,
      alerts: alerts,
    );
  }

  Future<void> _share(EmergencySummary summary) async {
    setState(() => _sharing = true);
    try {
      await const SummaryShareGateway().openShareSheet(summary.text);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open sharing. You can select and copy the text.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Emergency summary'),
      actions: [
        IconButton(
          tooltip: 'Refresh snapshot',
          icon: const Icon(Icons.refresh),
          onPressed: _sharing
              ? null
              : () {
                  final next = _capture();
                  setState(() {
                    _summary = next;
                  });
                },
        ),
      ],
    ),
    body: FutureBuilder<EmergencySummary>(
      future: _summary,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Could not prepare the local summary. Tap refresh to try again.',
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final summary = snapshot.data!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Review this snapshot before sharing. It stays fixed while you read; use refresh for a new snapshot.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SelectableText(
                  summary.text,
                  style: const TextStyle(height: 1.55),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.share_outlined),
                    label: Text(
                      summary.demo ? 'Share DEMO snapshot…' : 'Share snapshot…',
                    ),
                    onPressed: _sharing ? null : () => _share(summary),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
