import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Every SVG shipped in `assets/icons/` (mirrors design-system/icons/svg).
enum FarmIcon {
  arrowRight,
  barn,
  bell,
  calendar,
  chartLine,
  check,
  cloudSync,
  cow,
  duck,
  egg,
  eye,
  feedBag,
  goat,
  harvestBasket,
  heart,
  horse,
  inventory,
  language,
  leaf,
  location,
  medicine,
  milkBottle,
  money,
  poultry,
  pregnancy,
  qr,
  report,
  scale,
  settings,
  sheep,
  stethoscope,
  sun,
  syringe,
  task,
  tractor,
  warning,
}

extension on FarmIcon {
  String get _fileName {
    switch (this) {
      case FarmIcon.arrowRight:
        return 'arrow-right';
      case FarmIcon.chartLine:
        return 'chart-line';
      case FarmIcon.cloudSync:
        return 'cloud-sync';
      case FarmIcon.feedBag:
        return 'feed-bag';
      case FarmIcon.harvestBasket:
        return 'harvest-basket';
      case FarmIcon.milkBottle:
        return 'milk-bottle';
      default:
        return name;
    }
  }
}

/// Brand SVG icon, tinted with `color` via `currentColor`→`ColorFilter`.
class AppIcon extends StatelessWidget {
  const AppIcon(this.icon, {super.key, this.size = 22, this.color});

  final FarmIcon icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? IconTheme.of(context).color ?? Colors.black;
    return SvgPicture.asset(
      'assets/icons/${icon._fileName}.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
    );
  }
}
