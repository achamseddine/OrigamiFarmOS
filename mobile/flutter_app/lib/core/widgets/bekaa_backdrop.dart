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
  const BekaaBackdrop({super.key, this.warm = true, this.drift = 0});

  final bool warm;

  /// 0→1, wrapping. Drives the clouds and the flock of birds across the
  /// valley. Left at 0 the scene is a still painting, which is what the
  /// nav rail wants; the sign-in screen hands it a slow repeating
  /// animation instead, because a tablet somebody is waiting in front of
  /// should look alive rather than like a page that failed to finish
  /// loading.
  final double drift;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BekaaPainter(warm: warm, drift: drift),
      size: Size.infinite,
    );
  }
}

class _BekaaPainter extends CustomPainter {
  _BekaaPainter({required this.warm, this.drift = 0});
  final bool warm;
  final double drift;

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

    // Sun, with a soft halo so it reads as light rather than a sticker
    final sunCentre = Offset(size.width * 0.78, size.height * 0.22);
    final sunRadius = size.shortestSide * 0.06;
    canvas.drawCircle(
      sunCentre,
      sunRadius * 3.2,
      Paint()
        ..shader = RadialGradient(
          colors: [FarmColors.gold.withOpacity(0.30), FarmColors.gold.withOpacity(0)],
        ).createShader(Rect.fromCircle(center: sunCentre, radius: sunRadius * 3.2)),
    );
    canvas.drawCircle(sunCentre, sunRadius, Paint()..color = FarmColors.gold.withOpacity(0.85));

    _clouds(canvas, size);

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

    _birds(canvas, size);
  }

  /// Three soft cloud banks crossing the sky. Each has its own speed, so
  /// they separate and rejoin instead of moving as one sheet.
  void _clouds(Canvas canvas, Size size) {
    const banks = [
      (y: 0.14, scale: 1.0, speed: 1.0, opacity: 0.55),
      (y: 0.24, scale: 0.7, speed: 1.6, opacity: 0.40),
      (y: 0.09, scale: 1.4, speed: 0.6, opacity: 0.30),
    ];
    final paintBase = FarmColors.white;
    for (final bank in banks) {
      // Travel a full width plus the cloud's own width, so it is fully off
      // one edge before it reappears at the other — no popping.
      final w = size.width * 0.26 * bank.scale;
      final x = ((drift * bank.speed) % 1.0) * (size.width + w * 2) - w;
      final y = size.height * bank.y;
      final paint = Paint()..color = paintBase.withOpacity(bank.opacity);
      canvas.drawOval(Rect.fromCenter(center: Offset(x, y), width: w, height: w * 0.34), paint);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x - w * 0.22, y + w * 0.05), width: w * 0.62, height: w * 0.26),
        paint,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x + w * 0.26, y + w * 0.04), width: w * 0.54, height: w * 0.22),
        paint,
      );
    }
  }

  /// A small flock, drawn as open chevrons. They cross far more slowly
  /// than the clouds and are barely there — the point is that the screen
  /// is never completely still, not that anyone watches the birds.
  void _birds(Canvas canvas, Size size) {
    if (drift == 0) return;
    final paint = Paint()
      ..color = FarmColors.ink.withOpacity(0.28)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const flock = [(dx: 0.0, dy: 0.0, s: 1.0), (dx: -0.055, dy: 0.035, s: 0.8), (dx: -0.10, dy: -0.02, s: 0.9)];
    final lead = ((drift * 0.45) % 1.0) * (size.width * 1.3) - size.width * 0.15;
    for (final bird in flock) {
      final cx = lead + size.width * bird.dx;
      final cy = size.height * (0.30 + bird.dy);
      final w = size.shortestSide * 0.018 * bird.s;
      final path = Path()
        ..moveTo(cx - w, cy)
        ..quadraticBezierTo(cx - w * 0.5, cy - w * 0.6, cx, cy)
        ..quadraticBezierTo(cx + w * 0.5, cy - w * 0.6, cx + w, cy);
      canvas.drawPath(path, paint);
    }
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
  bool shouldRepaint(covariant _BekaaPainter oldDelegate) =>
      oldDelegate.warm != warm || oldDelegate.drift != drift;
}
