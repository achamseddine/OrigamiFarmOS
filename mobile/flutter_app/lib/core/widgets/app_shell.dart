import 'package:flutter/material.dart';
import 'nav_rail.dart';
import 'top_bar.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';

/// Tablet-first application shell: persistent left nav rail + top bar +
/// scrollable content canvas (tech spec component-spec.md "AppShell").
/// Target width 1024–1366px landscape; below [kTabletBreakpoint] the rail
/// collapses to icon-only so the shell still degrades gracefully.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.screens, this.initialIndex = 0});

  final List<Widget> screens;
  final int initialIndex;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index = widget.initialIndex;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < kTabletBreakpoint;

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Row(
          children: [
            NavRail(
              selectedIndex: _index,
              compact: compact,
              onSelect: (i) => setState(() => _index = i),
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
                        index: _index,
                        children: widget.screens,
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
