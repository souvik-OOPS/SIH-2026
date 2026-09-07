enum HistoryRange {
  quarterHour('15m', Duration(minutes: 15)),
  hour('1h', Duration(hours: 1)),
  sixHours('6h', Duration(hours: 6)),
  day('24h', Duration(days: 1)),
  week('7d', Duration(days: 7));

  const HistoryRange(this.label, this.duration);
  final String label;
  final Duration duration;
}

enum HistoryMetric {
  heartRate('hr', 'Heart rate', 'bpm', 10),
  oxygen('o2', 'Oxygen saturation', '%', 4),
  temperature('temperature', 'Air temperature', '°C', 4),
  humidity('humidity', 'Humidity', '%', 10);

  const HistoryMetric(this.key, this.label, this.unit, this.minimumSpan);
  final String key, label, unit;
  final double minimumSpan;
}

class MetricStatistics {
  const MetricStatistics({
    this.count = 0,
    this.average,
    this.minimum,
    this.maximum,
  });
  final int count;
  final double? average, minimum, maximum;
  factory MetricStatistics.fromRow(Map<String, Object?> row, String key) =>
      MetricStatistics(
        count: (row['${key}_count'] as num?)?.toInt() ?? 0,
        average: (row['${key}_avg'] as num?)?.toDouble(),
        minimum: (row['${key}_min'] as num?)?.toDouble(),
        maximum: (row['${key}_max'] as num?)?.toDouble(),
      );
}

class HistoryBucket {
  const HistoryBucket({
    required this.index,
    required this.samples,
    required this.metrics,
    this.interrupted = false,
  });
  final int index, samples;
  final bool interrupted;
  final Map<HistoryMetric, MetricStatistics> metrics;

  // A bin with any missing/unusable measurement is a gap for that metric.
  // It still contributes its valid values to the separately labelled statistics.
  double? plotValue(HistoryMetric metric) {
    final stat = metrics[metric];
    return !interrupted && stat != null && stat.count == samples
        ? stat.average
        : null;
  }
}

class HistorySnapshot {
  const HistorySnapshot({
    required this.since,
    required this.until,
    required this.demo,
    required this.bucketWidth,
    required this.buckets,
    required this.samples,
    required this.metrics,
  });
  final DateTime since, until;
  final bool demo;
  final Duration bucketWidth;
  final List<HistoryBucket> buckets;
  final int samples;
  final Map<HistoryMetric, MetricStatistics> metrics;
  DateTime bucketTime(HistoryBucket bucket) =>
      since.add(bucketWidth * bucket.index);
}
