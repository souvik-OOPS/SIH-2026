import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/monitoring/health_alert.dart';
import 'package:swasthyashield_edge/core/monitoring/history_snapshot.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_source.dart';
import 'package:swasthyashield_edge/features/monitoring/activity_screen.dart';
import 'package:swasthyashield_edge/features/monitoring/emergency_summary_screen.dart';
import 'package:swasthyashield_edge/features/monitoring/monitoring_controller.dart';
import 'package:swasthyashield_edge/features/monitoring/telemetry_session.dart';
import 'package:swasthyashield_edge/services/monitoring_store.dart';

class _Source implements TelemetrySource {
  @override
  Stream<TelemetryFrame> get frames => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _Store extends MonitoringStore {
  final requests = <({bool demo, Duration range})>[];

  @override
  Future<HistorySnapshot> history({
    required DateTime since,
    required DateTime until,
    required bool demo,
    int targetBuckets = 180,
  }) async {
    requests.add((demo: demo, range: until.difference(since)));
    return HistorySnapshot(
      since: since,
      until: until,
      demo: demo,
      bucketWidth: const Duration(seconds: 20),
      buckets: const [],
      samples: 0,
      metrics: {
        for (final metric in HistoryMetric.values)
          metric: const MetricStatistics(),
      },
    );
  }

  @override
  Future<List<HealthAlert>> alerts({
    bool? demo,
    DateTime? since,
    DateTime? until,
  }) async => [];

  @override
  Future<List<Map<String, Object?>>> readings({
    bool? demo,
    DateTime? since,
    DateTime? until,
  }) async => [];
}

void main() {
  late _Store store;
  late TelemetrySession session;
  late MonitoringController monitoring;
  void initialize() {
    store = _Store();
    session = TelemetrySession(source: _Source());
    monitoring = MonitoringController(session, store: store);
  }

  tearDown(() {
    monitoring.dispose();
    session.dispose();
  });

  testWidgets('history source, range and timer refresh update without errors', (
    tester,
  ) async {
    initialize();
    await tester.pumpWidget(
      MaterialApp(home: ActivityScreen(monitoring: monitoring)),
    );
    await tester.pumpAndSettle();
    expect(store.requests.last, (demo: false, range: const Duration(hours: 1)));

    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.requests.last.demo, isTrue);
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {true},
    );

    await tester.tap(find.text('24h'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.requests.last, (demo: true, range: const Duration(days: 1)));
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '24h'))
          .selected,
      isTrue,
    );

    final loads = store.requests.length;
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.requests.length, greaterThan(loads));
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'summary refresh works and shares exactly the reviewed snapshot',
    (tester) async {
      initialize();
      MethodCall? sent;
      const channel = MethodChannel('in.sih.swasthyashield/sharing');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        sent = call;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: EmergencySummaryScreen(monitoring: monitoring)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(sent, isNull);

      final loads = store.requests.length;
      await tester.tap(find.byTooltip('Refresh snapshot'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(store.requests.length, loads + 1);
      final preview = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data;
      await tester.tap(find.byIcon(Icons.share_outlined));
      await tester.pumpAndSettle();
      expect(sent?.method, 'shareSummary');
      expect(sent?.arguments, {'text': preview});
      expect(find.textContaining('sent successfully'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
