import 'package:flutter/material.dart';
import '../theme/colors.dart';

/// An original, lightweight vector illustration of the Bekaa Valley —
/// terraced fields, a ridge line, and a cedar silhouette — painted in brand
/// tones. The tech spec is explicit that the flattened Option C mockup PNGs
/// must never ship as in-app backgrounds (§19, §24): "Using screenshots as
/// UI backgrounds — the app must be real components with data." This paints
/// the valley as real vector geometry instead, so it is fully offline-safe
/// and matches "Bekaa Valley imagery... instead of foreign-looking farm
/// scenery" without depending on a licensed photo asset.
class BekaaBackdrop extends StatelessWidget {
  const BekaaBackdrop({super.key, this.warm = true});

  final bool warm;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BekaaPainter(warm: warm),
      size: Size.infinite,
    );
  }
}

class _BekaaPainter extends CustomPainter {
  _BekaaPainter({required this.warm});
  final bool warm;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Sky
    final sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: warm
            ? [FarmColors.stone, FarmColors.wheat.withOpacity(0.55)]
            : [FarmColors.mist, FarmColors.stone],
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    // Sun
    final sunPaint = Paint()..color = FarmColors.gold.withOpacity(0.85);
    canvas.drawCircle(Offset(size.width * 0.78, size.height * 0.22), size.width * 0.05, sunPaint);

    // Distant mountain ridge (Anti-Lebanon range silhouette)
    _ridge(canvas, size, heightFactor: 0.42, color: FarmColors.sand.withOpacity(0.9), seed: 1);
    // Mid ridge
    _ridge(canvas, size, heightFactor: 0.34, color: FarmColors.cedar2.withOpacity(0.30), seed: 2);
    // Valley floor with terraced field rows
    final floorTop = size.height * 0.62;
    final floorPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [FarmColors.olive.withOpacity(0.28), FarmColors.cedar.withOpacity(0.42)],
      ).createShader(Rect.fromLTWH(0, floorTop, size.width, size.height - floorTop));
    final floorPath = Path()
      ..moveTo(0, floorTop)
      ..lineTo(size.width, floorTop * 0.94)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(floorPath, floorPaint);

    // Terrace rows
    final rowPaint = Paint()
      ..color = FarmColors.cedar.withOpacity(0.16)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (var i = 1; i <= 6; i++) {
      final y = floorTop + (size.height - floorTop) * (i / 7);
      canvas.drawLine(Offset(0, y), Offset(size.width, y * 0.995), rowPaint);
    }

    // Cedar tree silhouette (Lebanon's emblem) anchored bottom-left
    _cedarTree(canvas, Offset(size.width * 0.09, size.height * 0.9), size.height * 0.32);
  }

  void _ridge(Canvas canvas, Size size, {required double heightFactor, required Color color, required int seed}) {
    final path = Path()..moveTo(0, size.height);
    final baseline = size.height * (1 - heightFactor);
    final points = <Offset>[
      Offset(0, baseline + 20 * seed),
      Offset(size.width * 0.16, baseline - 26),
      Offset(size.width * 0.30, baseline + 8),
      Offset(size.width * 0.46, baseline - 40 / seed),
      Offset(size.width * 0.62, baseline + 4),
      Offset(size.width * 0.80, baseline - 20),
      Offset(size.width * 0.92, baseline + 14),
      Offset(size.width, baseline - 6),
    ];
    path.lineTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _cedarTree(Canvas canvas, Offset base, double treeHeight) {
    final trunkPaint = Paint()..color = FarmColors.ink.withOpacity(0.5);
    canvas.drawRect(
      Rect.fromCenter(center: base.translate(0, -treeHeight * 0.06), width: 5, height: treeHeight * 0.16),
      trunkPaint,
    );
    final foliagePaint = Paint()..color = FarmColors.cedar.withOpacity(0.55);
    final tiers = 4;
    for (var i = 0; i < tiers; i++) {
      final tierWidth = treeHeight * (0.62 - i * 0.12);
      final tierY = base.dy - treeHeight * 0.16 - i * treeHeight * 0.18;
      final path = Path()
        ..moveTo(base.dx, tierY - treeHeight * 0.22)
        ..lineTo(base.dx - tierWidth / 2, tierY)
        ..lineTo(base.dx + tierWidth / 2, tierY)
        ..close();
      canvas.drawPath(path, foliagePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BekaaPainter oldDelegate) => oldDelegate.warm != warm;
}
