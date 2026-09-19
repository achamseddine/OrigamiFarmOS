import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'bottom_nav.dart';
import 'nav_rail.dart' show NavEntry;
import 'top_bar.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../../app/app_navigator.dart';
import '../../features/record/record_sheet.dart';
import '../../features/sync/sync_pill.dart';
import '../../providers/access_provider.dart';

/// Tablet application shell: content canvas over a bottom tab bar.
///
/// This used to be a 232px left nav rail of text labels with a utility
/// cluster pinned to the top-right corner — EN/AR, a bell, an avatar.
/// Both are web patterns, and together they made a farm tablet read as a
/// browser dashboard rather than an app.
///
/// What replaced them:
///   - Destinations moved to the bottom edge, where a thumb reaches them
///     while the tablet is held in two hands (see [BottomNav]). Anything
///     past the fourth lives behind More.
///   - The top strip keeps only what changes by itself and matters at a
///     glance: sync state, and the person signed in. Language lives in
///     Settings, which is a destination like any other.
///
/// [NavRail] is still in the tree for reference but nothing mounts it.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.entries, required this.screens});

  /// The permission-filtered nav entries — index-aligned with [screens]
  /// (see `app/nav_config.dart`, which builds both together so they can't
  /// drift apart).
  final List<NavEntry> entries;
  final List<Widget> screens;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < kTabletBreakpoint;
    // Which tab is showing lives in [AppNavigator], not here, so a
    // notification or a priority card can drive navigation too.
    final navigator = context.watch<AppNavigator>();
    final index = navigator.selectedIndex.clamp(0, screens.isEmpty ? 0 : screens.length - 1);
    final canRecord = recordActionsFor(context.watch<AccessProvider>()).isNotEmpty;

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TopBar(),
            // Only visible while the tablet is out of contact with the
            // farm server; collapses to nothing otherwise.
            const OfflineBanner(),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? FarmSpacing.md : FarmSpacing.lg,
                  vertical: FarmSpacing.sm,
                ),
                child: IndexedStack(
                  index: index,
                  children: screens,
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNav(
        entries: entries,
        selectedIndex: index,
        onSelect: navigator.select,
        // The centre button asks what to record rather than guessing at
        // one form, because the answer differs by who is holding the
        // tablet. It disappears entirely for someone who may not create
        // anything — a button that can only fail is worse than no button
        // (see [showRecordSheet]).
        onAction: canRecord ? () => showRecordSheet(context) : null,
      ),
    );
  }
}
