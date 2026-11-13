import 'package:flutter/material.dart';
import 'app_icon.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Small building blocks from the V3 farm-wide prototype
/// (`prototypes/origami-farmos-v3.html`), drawn in this app's tokens.
///
/// The prototype is a browser sketch on localStorage; what it settled is
/// the *anatomy* the screens share, and that is what lives here:
///
///   - an uppercase green **eyebrow** naming the area above every heading;
///   - an **empty state** that is a dashed box with an icon tile, so "no
///     records yet" reads as a place where records will go, not as a
///     broken screen;
///   - an amber **caution notice** wherever a screen could be misread as a
///     safety or financial clearance ("no flag here does not mean the milk
///     is safe");
///   - big **record tiles** for the handful of things a worker records at
///     an animal;
///   - a **fact list** of label/value rows for identity tables;
///   - an underlined **tab strip** for a record that has more sections
///     than one screen can hold.

/// The small uppercase line that names the area a heading belongs to.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color = FarmColors.cedar2});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: color),
    );
  }
}

/// Eyebrow, heading and one line of explanation, with the section's
/// actions at the far edge (under the text when there is no room).
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, this.eyebrow, required this.title, this.subtitle, this.actions = const []});
  final String? eyebrow;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow != null) ...[Eyebrow(eyebrow!), const SizedBox(height: 4)],
        Text(title, style: FarmTypography.display(size: 22)),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: FarmTypography.textTheme.bodySmall),
        ],
      ],
    );
    if (actions.isEmpty) return text;
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 560) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [text, const SizedBox(height: FarmSpacing.sm), Wrap(spacing: 8, runSpacing: 8, children: actions)],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: text),
          const SizedBox(width: FarmSpacing.md),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      );
    });
  }
}

/// "Nothing recorded yet", drawn as the place the records will go.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon = FarmIcon.calendar, this.detail, this.action, this.compact = false});
  final String message;
  final String? detail;
  final FarmIcon icon;

  /// Usually the button that records the first entry.
  final Widget? action;

  /// Less padding, for an empty list inside a busy card.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorder(color: FarmColors.border, radius: FarmRadii.sm),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: FarmSpacing.md, vertical: compact ? FarmSpacing.md : FarmSpacing.lg),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compact ? 36 : 44,
                height: compact ? 36 : 44,
                decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.xs)),
                child: Center(child: AppIcon(icon, size: compact ? 17 : 20, color: FarmColors.cedar)),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.muted),
              ),
              if (detail != null) ...[
                const SizedBox(height: 4),
                Text(detail!, textAlign: TextAlign.center, style: FarmTypography.textTheme.bodySmall),
              ],
              if (action != null) ...[const SizedBox(height: 12), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 5), paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorder oldDelegate) => oldDelegate.color != color || oldDelegate.radius != radius;
}

enum NoticeTone { caution, info, danger }

/// A boxed sentence that qualifies what the screen shows — never a
/// substitute for the server's own refusal, only the honest caveat beside
/// a figure that could be over-read.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.text, this.tone = NoticeTone.caution, this.title});
  final String text;
  final String? title;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final (fill, edge, ink, icon) = switch (tone) {
      NoticeTone.caution => (FarmColors.warningPale, FarmColors.tint(FarmColors.warning, 0.35), FarmColors.warningInk, Icons.info_outline),
      NoticeTone.info => (FarmColors.mist, FarmColors.tint(FarmColors.cedar, 0.25), FarmColors.cedarDark, Icons.info_outline),
      NoticeTone.danger => (FarmColors.dangerPale, FarmColors.tint(FarmColors.danger, 0.35), FarmColors.dangerInk, Icons.error_outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(FarmRadii.sm), border: Border.all(color: edge)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) Text(title!, style: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 12.5)),
                Text(text, style: TextStyle(color: ink, fontSize: 12.5, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One big tappable tile: an icon and what it records.
class RecordTile extends StatelessWidget {
  const RecordTile({super.key, required this.icon, required this.label, required this.onTap, this.accent = FarmColors.cedar});
  final FarmIcon icon;
  final String label;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FarmColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.sm), side: const BorderSide(color: FarmColors.border)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          constraints: const BoxConstraints(minHeight: 76),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AppIcon(icon, size: 20, color: accent),
              const SizedBox(height: 10),
              Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: FarmTypography.textTheme.titleSmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays out [children] in equal columns that wrap — the grid every KPI
/// row and tile set on these screens uses.
class EqualGrid extends StatelessWidget {
  const EqualGrid({super.key, required this.children, this.minTileWidth = 180, this.maxColumns = 4, this.spacing = FarmSpacing.md});
  final List<Widget> children;
  final double minTileWidth;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final fit = ((c.maxWidth + spacing) / (minTileWidth + spacing)).floor();
      final cols = fit.clamp(1, maxColumns);
      final w = (c.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final child in children) SizedBox(width: w, child: child)],
      );
    });
  }
}

/// A label on the reading edge, its value on the far one, a hairline under.
class FactRow extends StatelessWidget {
  const FactRow({super.key, required this.label, required this.value, this.valueColor, this.trailing, this.last = false});
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: FarmColors.border))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: FarmTypography.textTheme.bodySmall)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              value.isEmpty ? '—' : value,
              textAlign: TextAlign.end,
              style: FarmTypography.textTheme.titleSmall?.copyWith(color: valueColor),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
  }
}

/// An underlined tab strip that scrolls sideways when it runs out of room.
/// Selection is the caller's state, so the content under it can be any
/// height and live in the page's own scroll view.
class UnderlineTabs extends StatelessWidget {
  const UnderlineTabs({super.key, required this.labels, required this.selected, required this.onSelect});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: FarmColors.border))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Semantics(
                selected: i == selected,
                button: true,
                child: InkWell(
                  onTap: () => onSelect(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: i == selected ? FarmColors.cedarDark : Colors.transparent, width: 3)),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: i == selected ? FontWeight.w800 : FontWeight.w600,
                        color: i == selected ? FarmColors.ink : FarmColors.muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small rounded tag, the prototype's status chip: a soft fill and a
/// word. Use [StatusPill] where the tag carries a judgement (healthy,
/// alert); this one only describes (Female, Dairy Herd, Lactation 2).
class TagChip extends StatelessWidget {
  const TagChip(this.label, {super.key, this.color = FarmColors.cedar});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: FarmColors.tint(color, 0.12), borderRadius: BorderRadius.circular(FarmRadii.pill)),
      child: Text(label, style: TextStyle(color: color == FarmColors.cedar ? FarmColors.cedarDark : color, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}
