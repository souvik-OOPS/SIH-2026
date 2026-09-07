import 'package:flutter/material.dart';

import '../../core/models/vital_history.dart';

/// Heart-rate trend over roughly the last two minutes.
///
/// Hand-painted rather than pulled from a charting package: the whole figure is
/// one polyline, a fill and two labels, and the app already ships an offline
/// model and an assistant inside a 49 MB APK. A dependency would cost more than
/// it saves here.
class HeartRateChart extends StatelessWidget {
  const HeartRateChart({super.key, required this.history, required this.colour});

  final VitalHistory history;

  /// Trend colour, passed in so the chart follows the same signal palette the
  /// rest of the dashboard uses rather than choosing its own.
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!history.hasTrend) {
      return SizedBox(
        height: 92,
        child: Center(
          child: Text(
            history.isEmpty
                ? 'Waiting for readings'
                : 'Not enough readings yet for a trend',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final low = history.minimum!;
    final high = history.maximum!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 92,
          width: double.infinity,
          child: CustomPaint(
            painter: _HeartRateTrendPainter(
              samples: history.samples,
              colour: colour,
              gridColour: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.18),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              'last ${history.samples.length}s',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              '${low.round()}–${high.round()} bpm',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeartRateTrendPainter extends CustomPainter {
  _HeartRateTrendPainter({
    required this.samples,
    required this.colour,
    required this.gridColour,
  });

  final List<VitalSample> samples;
  final Color colour;
  final Color gridColour;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;

    final values = samples.where((s) => s.hasValue).map((s) => s.bpm!).toList();
    if (values.length < 2) return;

    var low = values.reduce((a, b) => a < b ? a : b);
    var high = values.reduce((a, b) => a > b ? a : b);

    // Give a flat trace room to sit in the middle instead of collapsing onto a
    // single row of pixels, and never let the span be so small that ordinary
    // beat-to-beat variation looks like a dramatic swing.
    const minimumSpan = 12.0;
    if (high - low < minimumSpan) {
      final centre = (high + low) / 2;
      low = centre - minimumSpan / 2;
      high = centre + minimumSpan / 2;
    }
    final span = high - low;

    double xFor(int index) => size.width * (index / (samples.length - 1));
    double yFor(double bpm) =>
        size.height - ((bpm - low) / span) * size.height;

    // Baseline grid: three lines, no numbers. The range is printed beneath the
    // chart, so labelling every gridline would only add clutter.
    final grid = Paint()
      ..color = gridColour
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * (i / 2);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Walk the samples, starting a new segment wherever a reading is missing.
    //
    // Connecting across a gap would draw a confident line through a period the
    // device had no reading for — the chart equivalent of inventing data. A
    // break is the honest rendering, and it also makes dropouts visible as
    // dropouts rather than as smooth stretches.
    final stroke = Paint()
      ..color = colour
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colour.withValues(alpha: 0.28), colour.withValues(alpha: 0.0)],
      ).createShader(Offset.zero & size);

    var segment = <Offset>[];

    void flush() {
      if (segment.length >= 2) {
        final line = Path()..moveTo(segment.first.dx, segment.first.dy);
        for (final point in segment.skip(1)) {
          line.lineTo(point.dx, point.dy);
        }

        final area = Path.from(line)
          ..lineTo(segment.last.dx, size.height)
          ..lineTo(segment.first.dx, size.height)
          ..close();
        canvas.drawPath(area, fill);
        canvas.drawPath(line, stroke);
      } else if (segment.length == 1) {
        // A lone trusted reading between two dropouts is still a fact worth
        // showing; a dot says so without implying a trend through it.
        canvas.drawCircle(segment.first, 2.2, Paint()..color = colour);
      }
      segment = <Offset>[];
    }

    for (var i = 0; i < samples.length; i++) {
      final bpm = samples[i].bpm;
      if (bpm == null) {
        flush();
        continue;
      }
      segment.add(Offset(xFor(i), yFor(bpm)));
    }
    flush();

    // Mark the most recent reading so the eye lands on "now".
    for (var i = samples.length - 1; i >= 0; i--) {
      final bpm = samples[i].bpm;
      if (bpm == null) continue;
      final at = Offset(xFor(i), yFor(bpm));
      canvas.drawCircle(at, 4.5, Paint()..color = colour.withValues(alpha: 0.25));
      canvas.drawCircle(at, 2.6, Paint()..color = colour);
      break;
    }
  }

  @override
  bool shouldRepaint(_HeartRateTrendPainter old) =>
      old.samples != samples || old.colour != colour;
}
