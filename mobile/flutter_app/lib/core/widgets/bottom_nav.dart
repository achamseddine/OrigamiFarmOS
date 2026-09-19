import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'nav_rail.dart' show NavEntry;
import '../i18n/strings.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Bottom tab bar (replaces the left nav rail).
///
/// The rail was a 232px sidebar of text labels, which is a *web* pattern —
/// it made a farm tablet read as a browser dashboard. A tablet app puts
/// its destinations along the bottom edge, where a thumb reaches them
/// while the device is held in two hands.
///
/// This app has up to thirteen destinations and a bar holds four, so the
/// rest live behind **More**, which opens a sheet. Which four are on the
/// bar is not a fixed list: the entries arriving here are already
/// filtered by what this person may open (see `app/nav_config.dart`), so
/// a worker with three modules gets three tabs and no More at all.
const double kBottomNavHeight = 88;

/// How far the centre action lifts above the bar.
const double _kActionLift = 22;
const double _kActionSize = 62;

class BottomNav extends StatelessWidget {
  const BottomNav({
    super.key,
    required this.entries,
    required this.selectedIndex,
    required this.onSelect,
    this.onAction,
  });

  /// Every destination this person may open, in nav order.
  final List<NavEntry> entries;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// The centre button. Null hides it and the bar becomes plain tabs.
  final VoidCallback? onAction;

  /// The four that get a tab of their own. Everything else goes to More.
  static const int _primaryCount = 4;

  bool get _needsMore => entries.length > _primaryCount;

  List<int> get _primary {
    // With a More button the bar shows three, plus More, plus the centre
    // action; without one it shows up to four.
    final room = _needsMore ? _primaryCount - 1 : _primaryCount;
    final indices = <int>[for (var i = 0; i < entries.length && i < room; i++) i];
    // Whatever is open must be visible on the bar, even when it lives in
    // the More sheet — otherwise nothing is highlighted and the person
    // cannot tell where they are.
    if (!indices.contains(selectedIndex) && selectedIndex < entries.length) {
      if (indices.isNotEmpty) indices[indices.length - 1] = selectedIndex;
    }
    return indices;
  }

  Future<void> _openMore(BuildContext context, List<int> hidden) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _MoreSheet(
        entries: entries,
        indices: hidden,
        selectedIndex: selectedIndex,
      ),
    );
    if (picked != null) onSelect(picked);
  }

  @override
  Widget build(BuildContext context) {
    final primary = _primary;
    final hidden = [
      for (var i = 0; i < entries.length; i++)
        if (!primary.contains(i)) i
    ];
    final moreIsActive = hidden.contains(selectedIndex);

    final slots = <Widget>[];
    final half = (primary.length / 2).ceil();
    for (var i = 0; i < primary.length; i++) {
      if (onAction != null && i == half) {
        slots.add(_ActionSlot(onTap: onAction!));
      }
      final index = primary[i];
      slots.add(_Tab(
        entry: entries[index],
        selected: index == selectedIndex,
        onTap: () => onSelect(index),
      ));
    }
    if (onAction != null && half >= primary.length) {
      slots.add(_ActionSlot(onTap: onAction!));
    }
    if (_needsMore) {
      slots.add(_Tab(
        entry: NavEntry(FarmIcon.inventory, 'navMore'),
        selected: moreIsActive,
        fallbackLabel: 'More',
        icon: Icons.grid_view_rounded,
        onTap: () => _openMore(context, hidden),
      ));
    }

    return Container(
      height: kBottomNavHeight + MediaQuery.paddingOf(context).bottom,
      decoration: const BoxDecoration(
        color: FarmColors.card,
        border: Border(top: BorderSide(color: FarmColors.border)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      // The centre action lifts above the bar, so nothing may clip it.
      child: OverflowBox(
        maxHeight: kBottomNavHeight + _kActionLift,
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: kBottomNavHeight + _kActionLift,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [for (final slot in slots) Expanded(child: slot)],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.fallbackLabel,
    this.icon,
  });

  final NavEntry entry;
  final bool selected;
  final VoidCallback onTap;

  /// Used by More, which is not a real destination and has no i18n key of
  /// its own in older string tables.
  final String? fallbackLabel;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = selected ? FarmColors.cedar : FarmColors.muted;
    var label = fallbackLabel ?? '';
    if (fallbackLabel == null) {
      label = context.t(entry.labelKey);
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: SizedBox(
        height: kBottomNavHeight,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null)
              Icon(icon, size: 25, color: color)
            else
              AppIcon(entry.icon, size: 25, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The centre action: record something, from wherever you are.
class _ActionSlot extends StatelessWidget {
  const _ActionSlot({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Semantics(
        button: true,
        label: 'Record',
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: _kActionSize,
            height: _kActionSize,
            child: CustomPaint(
              painter: _FoldedSquarePainter(
                face: FarmColors.cedar,
                under: FarmColors.cedarFold,
                radius: 19,
                fold: 17,
              ),
              child: const Center(
                child: Icon(Icons.add_rounded, size: 30, color: FarmColors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded square with its top-right corner turned back, the paper's
/// underside showing as a darker triangle. The origami cue, drawn rather
/// than faked with a rotated box so the fold lines up exactly.
class _FoldedSquarePainter extends CustomPainter {
  const _FoldedSquarePainter({
    required this.face,
    required this.under,
    required this.radius,
    required this.fold,
  });

  final Color face;
  final Color under;
  final double radius;
  final double fold;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(radius);
    final body = Path()
      ..moveTo(radius, 0)
      ..lineTo(size.width - fold, 0)
      ..lineTo(size.width, fold)
      ..lineTo(size.width, size.height - radius)
      ..arcToPoint(Offset(size.width - radius, size.height), radius: r)
      ..lineTo(radius, size.height)
      ..arcToPoint(Offset(0, size.height - radius), radius: r)
      ..lineTo(0, radius)
      ..arcToPoint(Offset(radius, 0), radius: r)
      ..close();
    canvas.drawPath(body, Paint()..color = face);

    final flap = Path()
      ..moveTo(size.width - fold, 0)
      ..lineTo(size.width, fold)
      ..lineTo(size.width - fold, fold)
      ..close();
    canvas.drawPath(flap, Paint()..color = under);
  }

  @override
  bool shouldRepaint(_FoldedSquarePainter old) =>
      old.face != face || old.under != under || old.radius != radius || old.fold != fold;
}

/// Everything that did not fit on the bar, as a grid you can hit.
class _MoreSheet extends StatelessWidget {
  const _MoreSheet({
    required this.entries,
    required this.indices,
    required this.selectedIndex,
  });

  final List<NavEntry> entries;
  final List<int> indices;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > kTabletBreakpoint ? 5 : 3;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(FarmSpacing.md),
        padding: const EdgeInsets.fromLTRB(
            FarmSpacing.md, FarmSpacing.sm, FarmSpacing.md, FarmSpacing.lg),
        decoration: BoxDecoration(
          color: FarmColors.card,
          borderRadius: BorderRadius.circular(FarmRadii.lg),
          boxShadow: FarmShadows.elevated,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: FarmSpacing.md),
                decoration: BoxDecoration(
                  color: FarmColors.border,
                  borderRadius: BorderRadius.circular(FarmRadii.pill),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: FarmSpacing.sm),
              child: Text('More', style: FarmTypography.textTheme.titleLarge),
            ),
            GridView.count(
              crossAxisCount: columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: FarmSpacing.sm,
              crossAxisSpacing: FarmSpacing.sm,
              childAspectRatio: 1.15,
              children: [
                for (final index in indices)
                  _MoreTile(
                    entry: entries[index],
                    selected: index == selectedIndex,
                    onTap: () => Navigator.of(context).pop(index),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.entry, required this.selected, required this.onTap});

  final NavEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? FarmColors.mist : FarmColors.stone,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Padding(
          padding: const EdgeInsets.all(FarmSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(entry.icon, size: 25, color: selected ? FarmColors.cedar : FarmColors.ink),
              const SizedBox(height: 10),
              Text(
                context.t(entry.labelKey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? FarmColors.cedar : FarmColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
