import 'dart:io';
import 'package:flutter/material.dart';
import 'app_icon.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';

/// A replaceable photo slot (tech spec §19: "Animal/product photos: Use
/// replaceable asset slots; avoid hardcoding generated images"). When no
/// photo has been captured yet it renders a calm brand-toned placeholder
/// instead of a stock/generated image, so the same widget upgrades cleanly
/// once a worker attaches a real photo from the tablet camera.
class PhotoSlot extends StatelessWidget {
  const PhotoSlot({
    super.key,
    this.filePath,
    this.icon = FarmIcon.cow,
    this.label,
    this.borderRadius,
    this.fit = BoxFit.cover,
  });

  final String? filePath;
  final FarmIcon icon;
  final String? label;
  final BorderRadius? borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? FarmRadii.card;
    final path = filePath;
    if (path != null && path.isNotEmpty) {
      // A path under assets/ is bundled imagery — the demo farm's animals
      // from the v1 asset pack. Anything else is a file the tablet's
      // camera wrote. The slot does not care which; a real farm's photos
      // replace the demo ones without touching this widget.
      final image = path.startsWith('assets/')
          ? Image.asset(path, fit: fit, errorBuilder: (_, __, ___) => _placeholder(radius))
          : Image.file(File(path), fit: fit, errorBuilder: (_, __, ___) => _placeholder(radius));
      return ClipRRect(borderRadius: radius, child: image);
    }
    return _placeholder(radius);
  }

  Widget _placeholder(BorderRadius radius) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FarmColors.mist, FarmColors.sand],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 30, color: FarmColors.cedar2.withOpacity(0.55)),
            if (label != null) ...[
              const SizedBox(height: 6),
              Text(
                label!,
                style: TextStyle(fontSize: 11, color: FarmColors.cedar2.withOpacity(0.6)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
