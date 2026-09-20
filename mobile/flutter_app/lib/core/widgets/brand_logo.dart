import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// The Origami mark — the green origami animal from the
/// `Origami_Option1_Mobile_Web_Icons` set. The same image is the launcher
/// icon and the splash on Android, rendered into `res/` from the 1024px
/// original; this is the in-app copy.
///
/// It is never mirrored for Arabic: a brand mark is a picture, not text.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/branding/origami-mark.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      matchTextDirection: false,
    );
  }
}

/// The mark with the name beside it. The icon set ships no wordmark, so
/// the name is set in the display face, two lines, cedar on the second —
/// the same lockup the sign-in card and the header used before, now
/// around the new mark. One widget so the three places it appears cannot
/// drift apart.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 44});

  /// Height of the mark; the wordmark scales with it.
  final double height;

  @override
  Widget build(BuildContext context) {
    final primary = height * 0.44;
    final secondary = height * 0.36;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: height),
        SizedBox(width: height * 0.22),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Origami', style: FarmTypography.display(size: primary, color: FarmColors.ink, height: 1.0)),
            Text('FarmOS', style: FarmTypography.display(size: secondary, color: FarmColors.cedar, height: 1.0)),
          ],
        ),
      ],
    );
  }
}
