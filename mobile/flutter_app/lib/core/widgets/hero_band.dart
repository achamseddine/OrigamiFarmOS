import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'bekaa_backdrop.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// The band of valley that opens a screen, with the screen's name on it.
///
/// From the v1 redesign review, where every screen starts on the
/// landscape rather than on a heading floating in space. The artwork is
/// the pack's `bekaa_header_panorama` — a text-free vector scene drawn
/// for exactly this, which is why it is a shallow wide one rather than
/// the sign-in screen's full landscape.
///
/// It bleeds past the page gutter on purpose. The shell pads its content,
/// and a hero that stops short of the screen edges reads as a picture
/// pasted into a document instead of the top of a screen — so the band
/// measures the window itself and draws to both edges, then pads its own
/// text back to the gutter.
class HeroBand extends StatelessWidget {
  const HeroBand({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.trailing,
    this.scenery = true,
    this.height,
  });

  /// Whether the valley is drawn behind the title.
  ///
  /// The pack is specific: the header panorama is for Morning, Animals
  /// and *selected* top-level farm pages, used lightly, and should not
  /// appear behind every screen. So the pages about the farm itself —
  /// the animals, the milk, the eggs, the feed, the fields, their
  /// health — keep it, and the pages about running the business (tasks,
  /// sales, staff, settings, the two module hubs) take the same band in
  /// plain paper. Same anatomy everywhere; the artwork only where it
  /// means something.
  final bool scenery;

  final String title;
  final String? subtitle;

  /// Drawn beside the title, at the size a screen title deserves.
  final FarmIcon? icon;

  /// Buttons for this screen — "add an animal", "download a report".
  /// They sit at the far edge on a wide tablet and under the title when
  /// there is no room for that.
  final List<Widget> actions;

  /// Anything else that belongs on the band but is not a button — the
  /// morning screen's motto, a module's status pill, a harvest reminder.
  /// Shown at the far edge on a wide tablet, dropped on a narrow one,
  /// because it is never the thing the screen is for.
  final Widget? trailing;

  /// Defaults to 170 with scenery, 128 without — a plain band has
  /// nothing to show above the title.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final height = this.height ?? (scenery ? 170 : 128);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final wide = screenWidth >= kTabletBreakpoint;
    final gutter = wide ? FarmSpacing.lg : FarmSpacing.md;

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FarmTypography.display(size: wide ? 34 : 26),
              ),
            ),
            if (icon != null) ...[
              const SizedBox(width: 12),
              AppIcon(icon!, size: wide ? 32 : 26, color: FarmColors.cedar),
            ],
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: FarmTypography.textTheme.bodyMedium?.copyWith(color: FarmColors.muted),
          ),
        ],
      ],
    );

    return SizedBox(
      height: height,
      child: OverflowBox(
        maxWidth: screenWidth,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: screenWidth,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (scenery) ...[
                const BekaaBackdrop(scene: BekaaScene.panorama),
                // The valley is scenery, not content — this keeps it well
                // behind the words without washing it out to nothing.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        FarmColors.stone.withOpacity(0.88),
                        FarmColors.stone.withOpacity(0.55),
                        FarmColors.stone.withOpacity(0.92),
                      ],
                    ),
                  ),
                ),
              ] else
                const DecoratedBox(decoration: BoxDecoration(color: FarmColors.surfaceSoft)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter, vertical: FarmSpacing.md),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: heading),
                          if (actions.isNotEmpty) ...[
                            const SizedBox(width: FarmSpacing.md),
                            Wrap(spacing: FarmSpacing.sm, runSpacing: FarmSpacing.sm, children: actions),
                          ],
                          if (trailing != null) ...[
                            const SizedBox(width: FarmSpacing.lg),
                            trailing!,
                          ],
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          heading,
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: FarmSpacing.md),
                            Wrap(spacing: FarmSpacing.sm, runSpacing: FarmSpacing.sm, children: actions),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small filled/outlined pair the review puts on a hero band.
class HeroAction extends StatelessWidget {
  const HeroAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  final String label;

  /// A pack icon — see `FarmIconMap` for the action constants (add,
  /// download, history) rather than picking one per screen.
  final FarmIcon icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.sm));
    if (primary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: AppIcon(icon, size: 20, color: FarmColors.white),
        label: Text(label),
        style: FilledButton.styleFrom(shape: shape, minimumSize: const Size(0, 52)),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: AppIcon(icon, size: 20, color: FarmColors.ink),
      label: Text(label),
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: const Size(0, 52),
        backgroundColor: FarmColors.card,
        foregroundColor: FarmColors.ink,
      ),
    );
  }
}
