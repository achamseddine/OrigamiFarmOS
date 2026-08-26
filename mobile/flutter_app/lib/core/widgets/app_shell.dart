import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'nav_rail.dart';
import 'top_bar.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../../app/app_navigator.dart';

/// Tablet-first application shell: persistent left nav rail + top bar +
/// scrollable content canvas (tech spec component-spec.md "AppShell").
/// Target width 1024–1366px landscape; below [kTabletBreakpoint] the rail
/// collapses to icon-only so the shell still degrades gracefully.
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

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Row(
          children: [
            NavRail(
              entries: entries,
              selectedIndex: index,
              compact: compact,
              onSelect: navigator.select,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TopBar(),
                  const Divider(height: 1, color: FarmColors.border),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? FarmSpacing.md : FarmSpacing.xl,
                        vertical: FarmSpacing.md,
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
          ],
        ),
      ),
    );
  }
}
