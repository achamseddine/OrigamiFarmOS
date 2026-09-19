import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'nav_rail.dart' show NavEntry;
import '../i18n/strings.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Bar height, from the asset pack's tablet tokens.
const double kBottomNavHeight = 92;

/// How far the centre action lifts above the bar.
const double _kActionLift = 22;
const double _kActionSize = 62;

/// Bottom tab bar (replaces the left nav rail).
///
/// The rail was a 232px sidebar of text labels, which is a *web* pattern —
/// it made a farm tablet read as a browser dashboard. A tablet app puts
/// its destinations along the bottom edge, where a thumb reaches them
/// while the device is held in two hands.
///
/// The shape is fixed, from the v1 redesign review: two destinations, the
/// record button, the profile, and More — the same five places on every
/// tablet, so "المزيد is bottom-left" is a thing a person learns once.
///
/// What the two destination slots *contain* is not fixed, and cannot be.
/// The entries arriving here are already filtered by what this person may
/// open (see `app/nav_config.dart`), so the slots take Morning and
/// Animals when they are among them — which for almost everyone they are
/// — and otherwise fall back to the first destinations this person
/// actually has. A tab nobody is allowed to open is a tab that answers a
/// tap with a 403, and no amount of consistency is worth that.
class BottomNav extends StatelessWidget {
  const BottomNav({
    super.key,
    required this.entries,
    required this.selectedIndex,
    required this.onSelect,
    this.onAction,
    this.onProfile,
  });

  /// Every destination this person may open, in nav order.
  final List<NavEntry> entries;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// The centre button. Null hides it.
  final VoidCallback? onAction;

  /// The profile tab. Null hides it.
  final VoidCallback? onProfile;

  /// The two destinations the review puts on the bar, by label key, in
  /// preference order.
  static const List<String> _preferred = ['navMorningBriefing', 'navAnimals'];
  static const int _slots = 2;

  /// Which entries get a tab of their own.
  List<int> get _primary {
    final chosen = <int>[];
    for (final key in _preferred) {
      final i = entries.indexWhere((e) => e.labelKey == key);
      if (i != -1 && !chosen.contains(i)) chosen.add(i);
      if (chosen.length == _slots) break;
    }
    for (var i = 0; i < entries.length && chosen.length < _slots; i++) {
      if (!chosen.contains(i)) chosen.add(i);
    }
    // Whatever is open must be visible on the bar, even when it lives in
    // the More sheet — otherwise nothing is highlighted and the person
    // cannot tell where they are.
    if (!chosen.contains(selectedIndex) && selectedIndex < entries.length && chosen.isNotEmpty) {
      chosen[chosen.length - 1] = selectedIndex;
    }
    return chosen;
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

    final slots = <Widget>[
      for (final index in primary)
        _Tab(
          entry: entries[index],
          selected: index == selectedIndex,
          onTap: () => onSelect(index),
        ),
      if (onAction != null) _ActionSlot(onTap: onAction!),
      if (onProfile != null)
        _Tab(
          entry: const NavEntry(FarmIcon.report, 'navProfile'),
          selected: false,
          onTap: onProfile!,
        ),
      if (hidden.isNotEmpty)
        _Tab(
          entry: const NavEntry(FarmIcon.inventory, 'navMore'),
          selected: moreIsActive,
          icon: Icons.grid_view_rounded,
          onTap: () => _openMore(context, hidden),
        ),
    ];

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
    this.icon,
  });

  final NavEntry entry;
  final bool selected;
  final VoidCallback onTap;

  /// More overrides the brand icon with a Material grid glyph; every real
  /// destination draws its own.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = selected ? FarmColors.cedar : FarmColors.muted;
    final label = context.t(entry.labelKey);

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
        label: context.t('record'),
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

/// Everything that did not fit on the bar, as a grid of subjects.
///
/// Built to the v1 redesign review: a big tinted roundel per
/// destination, its name, and one line saying what is behind it. The
/// line matters more than it looks — "المونة" alone is a word, "المونة /
/// المخزون والمواد" is a place you know whether you need.
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
    final columns = width > kTabletLandscapeMin ? 5 : (width > kTabletBreakpoint ? 4 : 2);

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(FarmSpacing.md),
        padding: const EdgeInsets.fromLTRB(
            FarmSpacing.lg, FarmSpacing.md, FarmSpacing.lg, FarmSpacing.lg),
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(context.t('navMore'), style: FarmTypography.display(size: 24)),
                          const SizedBox(width: 10),
                          const AppIcon(FarmIcon.leaf, size: 22, color: FarmColors.olive),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.t('moreSheetSubtitle'),
                        style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  tooltip: context.t('close'),
                  style: IconButton.styleFrom(backgroundColor: FarmColors.stone),
                ),
              ],
            ),
            const SizedBox(height: FarmSpacing.md),
            GridView.count(
              crossAxisCount: columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: FarmSpacing.md,
              crossAxisSpacing: FarmSpacing.md,
              childAspectRatio: 0.98,
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
          padding: const EdgeInsets.all(FarmSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: FarmColors.tint(entry.accent, 0.16),
                  shape: BoxShape.circle,
                ),
                child: Center(child: AppIcon(entry.icon, size: 30, color: entry.accent)),
              ),
              const SizedBox(height: 14),
              Text(
                context.t(entry.labelKey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: FarmColors.ink),
              ),
              const SizedBox(height: 4),
              Text(
                context.t('${entry.labelKey}Sub'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
