import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import '../core/monitoring/health_alert.dart';
import '../core/monitoring/history_snapshot.dart';

/// Local bounded journal. Never uploads health records.
class MonitoringStore {
  MonitoringStore({this.opener});
  final Future<Database> Function()? opener;
  Future<Database>? _opening;
  Future<Database> get database => _opening ??= (opener?.call() ?? _open());
  Future<Database> _open() async => openDatabase(
    path.join(await getDatabasesPath(), 'monitoring.db'),
    version: 1,
    onCreate: (db, _) => createSchema(db),
  );
  static Future<void> createSchema(Database db) async {
    await db.execute(
      'CREATE TABLE alerts(id TEXT PRIMARY KEY,type TEXT,title TEXT,body TEXT,at INTEGER,critical INTEGER,demo INTEGER,acknowledged INTEGER)',
    );
    await db.execute(
      'CREATE TABLE readings(at INTEGER PRIMARY KEY,hr REAL,o2 REAL,temperature REAL,humidity REAL,risk TEXT,trusted INTEGER,demo INTEGER)',
    );
  }

  Future<void> addAlert(HealthAlert alert) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'alerts',
        alert.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.rawDelete(
        'DELETE FROM alerts WHERE id NOT IN (SELECT id FROM alerts ORDER BY at DESC LIMIT 500)',
      );
    });
  }

  Future<List<HealthAlert>> alerts({
    bool? demo,
    DateTime? since,
    DateTime? until,
  }) async => (await (await database).query(
    'alerts',
    where: _filter(demo, since, until).$1,
    whereArgs: _filter(demo, since, until).$2,
    orderBy: 'at DESC',
    limit: 500,
  )).map(HealthAlert.fromRow).toList();
  Future<void> acknowledge(String id) async => (await database).update(
    'alerts',
    {'acknowledged': 1},
    where: 'id = ?',
    whereArgs: [id],
  );
  Future<void> record(Map<String, Object?> row) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'readings',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'readings',
        where: 'at < ?',
        whereArgs: [
          (row['at'] as int) - const Duration(days: 7).inMilliseconds,
        ],
      );
    });
  }

  Future<List<Map<String, Object?>>> readings({
    bool? demo,
    DateTime? since,
    DateTime? until,
  }) async => (await database).query(
    'readings',
    where: _filter(demo, since, until).$1,
    whereArgs: _filter(demo, since, until).$2,
    orderBy: 'at DESC',
    limit: 720,
  );

  (String?, List<Object>) _filter(
    bool? demo,
    DateTime? since,
    DateTime? until,
  ) {
    final terms = <String>[], args = <Object>[];
    if (demo != null) {
      terms.add('demo = ?');
      args.add(demo ? 1 : 0);
    }
    if (since != null) {
      terms.add('at >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    if (until != null) {
      terms.add('at <= ?');
      args.add(until.millisecondsSinceEpoch);
    }
    return (terms.isEmpty ? null : terms.join(' AND '), args);
  }

  /// Aggregate in SQLite: even a seven-day view returns at most 181 buckets,
  /// while statistics use every valid sample, not averages of bucket averages.
  Future<HistorySnapshot> history({
    required DateTime since,
    required DateTime until,
    required bool demo,
    int targetBuckets = 180,
  }) async {
    if (!until.isAfter(since)) {
      throw ArgumentError('History range must be positive');
    }
    final width =
        (until.difference(since).inMilliseconds / targetBuckets.clamp(1, 500))
            .ceil()
            .clamp(10000, 604800000);
    final filter = _filter(demo, since, until);
    final source = '''SELECT at,
      CASE WHEN trusted = 1 THEN hr END AS hr,
      CASE WHEN trusted = 1 THEN o2 END AS o2, temperature, humidity,
      CASE WHEN at - (SELECT MAX(previous.at) FROM readings AS previous
        WHERE previous.at < readings.at AND previous.demo = readings.demo
        AND previous.at >= ?) > 20000 THEN 1 ELSE 0 END AS interrupted
      FROM readings WHERE ${filter.$1}''';
    final aggregate = [
      'COUNT(*) AS samples',
      'MAX(interrupted) AS interrupted',
      for (final m in HistoryMetric.values)
        'COUNT(${m.key}) AS ${m.key}_count, AVG(${m.key}) AS ${m.key}_avg, '
            'MIN(${m.key}) AS ${m.key}_min, MAX(${m.key}) AS ${m.key}_max',
    ].join(', ');
    final db = await database;
    return db.transaction((txn) async {
      final totals = (await txn.rawQuery('SELECT $aggregate FROM ($source)', [
        since.millisecondsSinceEpoch,
        ...filter.$2,
      ])).single;
      final rows = await txn.rawQuery(
        'SELECT CAST((at - ?) / ? AS INTEGER) AS bucket, $aggregate '
        'FROM ($source) GROUP BY bucket ORDER BY bucket',
        [
          since.millisecondsSinceEpoch,
          width,
          since.millisecondsSinceEpoch,
          ...filter.$2,
        ],
      );
      Map<HistoryMetric, MetricStatistics> metrics(Map<String, Object?> row) =>
          {
            for (final m in HistoryMetric.values)
              m: MetricStatistics.fromRow(row, m.key),
          };
      return HistorySnapshot(
        since: since,
        until: until,
        demo: demo,
        bucketWidth: Duration(milliseconds: width),
        samples: (totals['samples'] as num).toInt(),
        metrics: metrics(totals),
        buckets: [
          for (final row in rows)
            HistoryBucket(
              index: (row['bucket'] as num).toInt(),
              samples: (row['samples'] as num).toInt(),
              interrupted: row['interrupted'] == 1,
              metrics: metrics(row),
            ),
        ],
      );
    });
  }

  Future<void> clear() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('alerts');
      await txn.delete('readings');
    });
  }
}
