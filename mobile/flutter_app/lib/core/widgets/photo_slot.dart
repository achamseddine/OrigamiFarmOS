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
    if (filePath != null && filePath!.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(File(filePath!), fit: fit, errorBuilder: (_, __, ___) => _placeholder(radius)),
      );
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
