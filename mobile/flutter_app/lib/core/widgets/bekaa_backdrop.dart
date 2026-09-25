import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/colors.dart';

/// The Bekaa Valley scenery behind the sign-in screen and every screen
/// header.
///
/// This used to be geometry painted here in Dart, because there was no
/// artwork to ship — the tech spec forbids putting the flattened mockup
/// PNGs behind the UI (§19, §24), and nothing else existed. The v1 asset
/// pack supplies the real thing: two text-free vector scenes drawn for
/// the product, `bekaa_landscape_login` and `bekaa_header_panorama`. They
/// are the approved artwork, so they are what the app draws.
///
/// The weather is still ours. The pack's scenes are still paintings, and
/// a sign-in screen somebody is standing in front of should not be. The
/// clouds and the flock are painted over the scene from [drift], so the
/// artwork is exactly as delivered and the sky moves.
enum BekaaScene {
  /// Full-height scene for the sign-in screen.
  login('assets/backgrounds/bekaa_landscape_login.svg'),

  /// Wide, shallow panorama for a screen header.
  panorama('assets/backgrounds/bekaa_header_panorama.svg');

  const BekaaScene(this.asset);
  final String asset;
}

class BekaaBackdrop extends StatelessWidget {
  const BekaaBackdrop({
    super.key,
    this.scene = BekaaScene.login,
    this.drift = 0,
  });

  final BekaaScene scene;

  /// 0→1, wrapping. Drives the clouds and the flock. Left at 0 the scene
  /// is a still painting, which is what a screen header wants; the
  /// sign-in screen hands it a slow repeating animation instead.
  final double drift;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // fitWidth, not cover. The scenes are wide (1600x900); on the
        // sign-in screen's tall half-panel `cover` zooms until only a
        // slice of hillside is left and the farm, the cedar and the
        // ridge line are all outside the frame. Fitting the width keeps
        // the whole valley and crops the sky instead, which is the part
        // with nothing in it.
        Align(
          alignment: Alignment.bottomCenter,
          child: SvgPicture.asset(
            scene.asset,
            fit: BoxFit.fitWidth,
            width: double.infinity,
            alignment: Alignment.bottomCenter,
          ),
        ),
        if (drift > 0)
          CustomPaint(painter: _WeatherPainter(drift: drift), size: Size.infinite),
      ],
    );
  }
}

/// Clouds and a small flock, over whatever scene is underneath.
class _WeatherPainter extends CustomPainter {
  const _WeatherPainter({required this.drift});

  final double drift;

  @override
  void paint(Canvas canvas, Size size) {
    _clouds(canvas, size);
    _birds(canvas, size);
  }

  /// Three soft cloud banks crossing the sky. Each has its own speed, so
  /// they separate and rejoin instead of moving as one sheet.
  void _clouds(Canvas canvas, Size size) {
    const banks = [
      (y: 0.14, scale: 1.0, speed: 1.0, opacity: 0.50),
      (y: 0.24, scale: 0.7, speed: 1.6, opacity: 0.36),
      (y: 0.09, scale: 1.4, speed: 0.6, opacity: 0.28),
    ];
    for (final bank in banks) {
      // Travel a full width plus the cloud's own width, so it is fully off
      // one edge before it reappears at the other — no popping.
      final w = size.width * 0.26 * bank.scale;
      final x = ((drift * bank.speed) % 1.0) * (size.width + w * 2) - w;
      final y = size.height * bank.y;
      final paint = Paint()..color = FarmColors.white.withOpacity(bank.opacity);
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
    final paint = Paint()
      ..color = FarmColors.ink.withOpacity(0.26)
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

  @override
  bool shouldRepaint(covariant _WeatherPainter oldDelegate) => oldDelegate.drift != drift;
}
