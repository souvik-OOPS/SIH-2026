import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swasthyashield_edge/core/monitoring/health_alert.dart';
import 'package:swasthyashield_edge/core/monitoring/history_snapshot.dart';
import 'package:swasthyashield_edge/services/monitoring_store.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late MonitoringStore store;
  final start = DateTime.utc(2026, 9, 7, 12);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await MonitoringStore.createSchema(db);
    store = MonitoringStore(opener: () async => db);
  });
  tearDown(() async => db.close());
  Future<void> sample(
    int seconds, {
    double? hr = 80,
    bool trusted = true,
    bool demo = false,
  }) => db.insert('readings', {
    'at': start.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
    'hr': hr,
    'o2': 98,
    'temperature': 30,
    'humidity': 60,
    'trusted': trusted ? 1 : 0,
    'demo': demo ? 1 : 0,
    'risk': 'normal',
  });

  test(
    'range queries isolate demo/future/old data; means are sample weighted',
    () async {
      await sample(-10, hr: 200);
      await sample(0, hr: 60);
      await sample(10, hr: 90);
      await sample(20, hr: 150);
      await sample(70, hr: 40);
      await sample(80, hr: 220, demo: true);
      await sample(121, hr: 220);
      final h = await store.history(
        since: start,
        until: start.add(const Duration(seconds: 120)),
        demo: false,
        targetBuckets: 2,
      );
      expect(h.samples, 4);
      expect(h.buckets, hasLength(2));
      expect(h.metrics[HistoryMetric.heartRate]!.average, 85);
      expect(h.metrics[HistoryMetric.heartRate]!.minimum, 40);
      expect(h.metrics[HistoryMetric.heartRate]!.maximum, 150);
      expect(
        await store.readings(
          since: start,
          until: start.add(const Duration(seconds: 120)),
          demo: true,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'untrusted pulse is excluded and a mixed-validity bin breaks its line',
    () async {
      await sample(0, hr: 80);
      await sample(5, hr: 240, trusted: false);
      await sample(10, hr: 90);
      final h = await store.history(
        since: start,
        until: start.add(const Duration(seconds: 20)),
        demo: false,
        targetBuckets: 2,
      );
      expect(h.metrics[HistoryMetric.heartRate]!.count, 2);
      expect(h.metrics[HistoryMetric.heartRate]!.average, 85);
      expect(h.buckets.first.plotValue(HistoryMetric.heartRate), isNull);
      expect(h.buckets.first.plotValue(HistoryMetric.temperature), 30);
      expect(h.buckets.last.plotValue(HistoryMetric.heartRate), 90);
    },
  );

  test('an outage within one coarse bucket still breaks the trend', () async {
    await sample(0);
    await sample(10);
    await sample(50);
    final h = await store.history(
      since: start,
      until: start.add(const Duration(minutes: 1)),
      demo: false,
      targetBuckets: 1,
    );
    expect(h.buckets.single.interrupted, isTrue);
    expect(h.buckets.single.plotValue(HistoryMetric.heartRate), isNull);
    expect(h.metrics[HistoryMetric.heartRate]!.count, 3);
  });

  test(
    'long histories are bounded for plotting without the raw-list 720 cap',
    () async {
      final batch = db.batch();
      for (var i = 0; i < 2000; i++) {
        batch.insert('readings', {
          'at': start.add(Duration(seconds: i * 10)).millisecondsSinceEpoch,
          'hr': 80,
          'trusted': 1,
          'demo': 0,
        });
      }
      await batch.commit(noResult: true);
      final h = await store.history(
        since: start,
        until: start.add(const Duration(days: 1)),
        demo: false,
      );
      expect(h.samples, 2000);
      expect(h.metrics[HistoryMetric.heartRate]!.count, 2000);
      expect(h.buckets.length, lessThanOrEqualTo(181));
      expect(await store.readings(), hasLength(720));
    },
  );

  test(
    'empty history has unavailable statistics, and alerts use the same filter',
    () async {
      final end = start.add(const Duration(hours: 1));
      final h = await store.history(since: start, until: end, demo: false);
      expect(h.samples, 0);
      expect(h.metrics[HistoryMetric.heartRate]!.average, isNull);
      for (final demo in [false, true]) {
        await store.addAlert(
          HealthAlert(
            id: '$demo',
            type: 'fall',
            title: 'Possible fall',
            body: 'Check in',
            at: start,
            critical: true,
            demo: demo,
          ),
        );
      }
      final alerts = await store.alerts(demo: false, since: start, until: end);
      expect(alerts.single.demo, isFalse);
      await store.acknowledge(alerts.single.id);
      expect((await store.alerts(demo: false)).single.acknowledged, isTrue);
    },
  );
}
