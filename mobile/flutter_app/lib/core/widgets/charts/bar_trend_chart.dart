import 'package:flutter/material.dart';
import '../../theme/colors.dart';

/// One bar in a [BarTrendChart]. `segments` stack bottom-to-top so the same
/// widget can render a simple bar (one segment) or a stacked bar
/// (e.g. morning + evening milk).
class BarGroup {
  const BarGroup({required this.label, required this.segments, this.outlined = false});

  final String label;
  final List<double> segments;
  final bool outlined;
}

/// A dependency-free stacked/grouped bar chart with an optional dashed
/// overlay line (e.g. a "total" trend across stacked segments).
class BarTrendChart extends StatelessWidget {
  const BarTrendChart({
    super.key,
    required this.bars,
    this.segmentColors = const [FarmColors.olive, FarmColors.cedar],
    this.overlayLine,
    this.overlayColor = FarmColors.cedar,
    this.height = 160,
  });

  final List<BarGroup> bars;
  final List<Color> segmentColors;
  final List<double>? overlayLine;
  final Color overlayColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomPaint(
              painter: _BarTrendPainter(
                bars: bars,
                segmentColors: segmentColors,
                overlayLine: overlayLine,
                overlayColor: overlayColor,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final bar in bars)
                Expanded(
                  child: Text(
                    bar.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10.5, color: FarmColors.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BarTrendPainter extends CustomPainter {
  _BarTrendPainter({
    required this.bars,
    required this.segmentColors,
    required this.overlayLine,
    required this.overlayColor,
  });

  final List<BarGroup> bars;
  final List<Color> segmentColors;
  final List<double>? overlayLine;
  final Color overlayColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final totals = bars.map((b) => b.segments.fold<double>(0, (a, b2) => a + b2)).toList();
    final overlayMax =
        overlayLine != null && overlayLine!.isNotEmpty ? overlayLine!.reduce((a, b) => a > b ? a : b) : 0.0;
    final maxV = [...totals, overlayMax].reduce((a, b) => a > b ? a : b);
    final safeMax = maxV <= 0 ? 1.0 : maxV * 1.12;

    final slot = size.width / bars.length;
    final barWidth = (slot * 0.46).clamp(10.0, 42.0).toDouble();

    for (var i = 0; i < bars.length; i++) {
      final group = bars[i];
      final centerX = slot * i + slot / 2;
      double baseY = size.height;
      for (var s = 0; s < group.segments.length; s++) {
        final value = group.segments[s];
        final segHeight = size.height * (value / safeMax);
        final rect = Rect.fromLTWH(
          centerX - barWidth / 2,
          baseY - segHeight,
          barWidth,
          segHeight,
        );
        final color = segmentColors[s % segmentColors.length];
        final rrect = RRect.fromRectAndCorners(
          rect,
          topLeft: s == group.segments.length - 1 ? const Radius.circular(4) : Radius.zero,
          topRight: s == group.segments.length - 1 ? const Radius.circular(4) : Radius.zero,
        );
        final paint = Paint()
          ..color = group.outlined ? color.withOpacity(0.35) : color
          ..style = group.outlined ? PaintingStyle.stroke : PaintingStyle.fill
          ..strokeWidth = 1.6;
        canvas.drawRRect(rrect, paint);
        baseY -= segHeight;
      }
    }

    if (overlayLine != null && overlayLine!.length == bars.length) {
      final points = <Offset>[];
      for (var i = 0; i < overlayLine!.length; i++) {
        final centerX = slot * i + slot / 2;
        final y = size.height * (1 - overlayLine![i] / safeMax);
        points.add(Offset(centerX, y));
      }
      final linePaint = Paint()
        ..color = overlayColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      const dash = 5.0, gap = 4.0;
      for (var i = 0; i < points.length - 1; i++) {
        final start = points[i];
        final end = points[i + 1];
        final seg = end - start;
        final dist = seg.distance;
        if (dist == 0) continue;
        final dir = seg / dist;
        double covered = 0;
        while (covered < dist) {
          final segEndDistance = covered + dash > dist ? dist : covered + dash;
          canvas.drawLine(start + dir * covered, start + dir * segEndDistance, linePaint);
          covered += dash + gap;
        }
      }
      final dotPaint = Paint()..color = overlayColor;
      for (final p in points) {
        canvas.drawCircle(p, 2.6, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarTrendPainter oldDelegate) => true;
}
