import 'package:flutter/material.dart';
import '../../theme/colors.dart';

/// A lightweight, dependency-free line/area chart painted directly from
/// data (tech spec §19: "Charts: Render from data, not static screenshots").
///
/// Supports an optional dashed secondary series (e.g. "last week" baseline)
/// and an optional area fill under the primary series.
class LineTrendChart extends StatelessWidget {
  const LineTrendChart({
    super.key,
    required this.values,
    this.secondaryValues,
    this.labels = const [],
    this.color = FarmColors.cedar,
    this.secondaryColor = FarmColors.muted,
    this.fill = true,
    this.height = 140,
    this.showDots = true,
  });

  final List<double> values;
  final List<double>? secondaryValues;
  final List<String> labels;
  final Color color;
  final Color secondaryColor;
  final bool fill;
  final double height;
  final bool showDots;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomPaint(
              painter: _LineTrendPainter(
                values: values,
                secondaryValues: secondaryValues,
                color: color,
                secondaryColor: secondaryColor,
                fill: fill,
                showDots: showDots,
              ),
              size: Size.infinite,
            ),
          ),
          if (labels.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(labels.first,
                    style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                if (labels.length > 1)
                  Text(labels.last,
                      style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LineTrendPainter extends CustomPainter {
  _LineTrendPainter({
    required this.values,
    required this.secondaryValues,
    required this.color,
    required this.secondaryColor,
    required this.fill,
    required this.showDots,
  });

  final List<double> values;
  final List<double>? secondaryValues;
  final Color color;
  final Color secondaryColor;
  final bool fill;
  final bool showDots;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final allValues = [...values, ...?secondaryValues];
    final maxV = allValues.reduce((a, b) => a > b ? a : b);
    final minV = allValues.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);

    const topPad = 8.0;
    const bottomPad = 4.0;
    final chartHeight = size.height - topPad - bottomPad;

    Offset pointFor(int i, double v, int count) {
      final dx = count <= 1 ? 0.0 : size.width * (i / (count - 1));
      final dy = topPad + chartHeight * (1 - (v - minV) / range);
      return Offset(dx, dy);
    }

    if (secondaryValues != null && secondaryValues!.isNotEmpty) {
      _drawDashedLine(canvas, secondaryValues!, pointFor, secondaryColor, size);
    }

    final points = [
      for (var i = 0; i < values.length; i++) pointFor(i, values[i], values.length)
    ];

    if (fill && points.length > 1) {
      final fillPath = Path()..moveTo(points.first.dx, size.height);
      for (final p in points) {
        fillPath.lineTo(p.dx, p.dy);
      }
      fillPath.lineTo(points.last.dx, size.height);
      fillPath.close();
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.22), color.withOpacity(0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawPath(fillPath, fillPaint);
    }

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final linePath = Path();
    for (var i = 0; i < points.length; i++) {
      if (i == 0) {
        linePath.moveTo(points[i].dx, points[i].dy);
      } else {
        linePath.lineTo(points[i].dx, points[i].dy);
      }
    }
    canvas.drawPath(linePath, linePaint);

    if (showDots) {
      final dotPaint = Paint()..color = color;
      final ringPaint = Paint()
        ..color = FarmColors.card
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final p in points) {
        canvas.drawCircle(p, 3.4, dotPaint);
        canvas.drawCircle(p, 3.4, ringPaint);
      }
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    List<double> series,
    Offset Function(int, double, int) pointFor,
    Color dashColor,
    Size size,
  ) {
    final points = [for (var i = 0; i < series.length; i++) pointFor(i, series[i], series.length)];
    final paint = Paint()
      ..color = dashColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    const dashWidth = 5.0;
    const dashGap = 4.0;

    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      final segment = end - start;
      final distance = segment.distance;
      if (distance == 0) continue;
      final direction = segment / distance;
      double covered = 0;
      while (covered < distance) {
        final segStart = start + direction * covered;
        final segEndDistance = covered + dashWidth > distance ? distance : covered + dashWidth;
        final segEnd = start + direction * segEndDistance;
        canvas.drawLine(segStart, segEnd, paint);
        covered += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LineTrendPainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.secondaryValues != secondaryValues ||
        oldDelegate.color != color;
  }
}
