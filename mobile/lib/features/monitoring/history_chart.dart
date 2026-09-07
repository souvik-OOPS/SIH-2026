import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/monitoring/history_snapshot.dart';

/// Bounded, interactive plots. Empty or partially invalid bins break the line.
class HistoryChart extends StatefulWidget {
  const HistoryChart({super.key, required this.history, required this.metric});
  final HistorySnapshot history;
  final HistoryMetric metric;
  @override
  State<HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends State<HistoryChart> {
  HistoryBucket? _selected;
  @override
  void didUpdateWidget(HistoryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.history != widget.history) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.history, m = widget.metric;
    final stats = h.metrics[m]!;
    final color = Theme.of(context).colorScheme.primary;
    String value(double? v) =>
        v?.toStringAsFixed(m == HistoryMetric.temperature ? 1 : 0) ?? '—';
    final plotted = h.buckets.where((b) => b.plotValue(m) != null).toList();
    final selected = _selected;
    final selectedStats = selected?.metrics[m];
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '${value(stats.average)} ${m.unit} average',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: color),
            ),
            Text(
              'Min ${value(stats.minimum)} · Max ${value(stats.maximum)} · ${stats.count} usable samples',
            ),
            const SizedBox(height: 12),
            if (plotted.isEmpty)
              SizedBox(
                height: 110,
                child: Center(
                  child: Text(
                    stats.count == 0
                        ? 'No usable ${m.label.toLowerCase()} readings in this period.'
                        : 'No complete usable intervals. Try a shorter range.',
                  ),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) => Semantics(
                  label: '${m.label} trend. Tap to inspect an interval.',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      final fraction =
                          ((details.localPosition.dx - 42) /
                                  (constraints.maxWidth - 52))
                              .clamp(0.0, 1.0);
                      final wanted =
                          fraction *
                          h.until.difference(h.since).inMilliseconds /
                          h.bucketWidth.inMilliseconds;
                      final matches = h.buckets.where(
                        (b) => b.index == wanted.floor(),
                      );
                      setState(
                        () => _selected = matches.isEmpty
                            ? HistoryBucket(
                                index: wanted.floor(),
                                samples: 0,
                                metrics: const {},
                              )
                            : matches.first,
                      );
                    },
                    child: SizedBox(
                      height: 155,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _TrendPainter(
                          h,
                          m,
                          color,
                          Theme.of(context).colorScheme.onSurfaceVariant,
                          selected?.index,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (selected != null) ...[
              const SizedBox(height: 8),
              Text(
                '${_time(h.bucketTime(selected))} · ${selected.plotValue(m) == null ? 'Gap: missing or unreliable measurements' : '${value(selectedStats?.average)} ${m.unit} average · range ${value(selectedStats?.minimum)}–${value(selectedStats?.maximum)}'}',
                key: ValueKey('history-detail-${m.key}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _time(DateTime time) {
  final at = time.toLocal();
  return '${at.day}/${at.month} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(
    this.history,
    this.metric,
    this.color,
    this.labelColor,
    this.selected,
  );
  final HistorySnapshot history;
  final HistoryMetric metric;
  final Color color, labelColor;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final stats = history.metrics[metric]!;
    final low = stats.minimum ?? 0, high = stats.maximum ?? 0;
    final span = math.max(high - low, metric.minimumSpan);
    final center = (low + high) / 2;
    final yMin = center - span * .6, yMax = center + span * .6;
    final plot = Rect.fromLTRB(42, 8, size.width - 10, size.height - 28);
    final duration = history.until.difference(history.since).inMilliseconds;
    double x(int index) =>
        plot.left +
        plot.width *
            (index * history.bucketWidth.inMilliseconds / duration).clamp(
              0.0,
              1.0,
            );
    double y(double value) =>
        plot.bottom - (value - yMin) / (yMax - yMin) * plot.height;
    void label(String text, Offset offset) {
      final p = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: labelColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, offset);
    }

    final grid = Paint()
      ..color = labelColor.withValues(alpha: .16)
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final v = yMin + (yMax - yMin) * i / 2;
      canvas.drawLine(Offset(plot.left, y(v)), Offset(plot.right, y(v)), grid);
      label(
        v.toStringAsFixed(metric == HistoryMetric.temperature ? 1 : 0),
        Offset(0, y(v) - 6),
      );
    }
    label(_time(history.since), Offset(plot.left, plot.bottom + 9));
    label(
      _time(history.until),
      Offset(math.max(plot.left, plot.right - 78), plot.bottom + 9),
    );
    final path = Path();
    int? previous;
    for (final bucket in history.buckets) {
      final v = bucket.plotValue(metric);
      if (v == null) {
        previous = null;
        continue;
      }
      final p = Offset(x(bucket.index), y(v));
      if (previous == null || bucket.index != previous + 1) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawCircle(p, 1.8, Paint()..color = color);
      previous = bucket.index;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    if (selected != null) {
      canvas.drawLine(
        Offset(x(selected!), plot.top),
        Offset(x(selected!), plot.bottom),
        Paint()
          ..color = color.withValues(alpha: .5)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.history != history ||
      old.metric != metric ||
      old.color != color ||
      old.labelColor != labelColor ||
      old.selected != selected;
}
