import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import 'ux_blocks.dart';

/// A module laid out as one page — Feed, Health, Mouneh, Farm Visits.
///
/// The band and figures at the top scroll away with the page, the tab bar
/// then stays at the top of the screen, and the chosen tab is shown at its
/// full height. Tabs are never drawn in a window of their own under the
/// header: on a tablet that window was a few lines tall, and a mix, the
/// day's feeding or a report scrolled inside it unreadably.
///
/// A tab is built the first time it is opened and keeps what was typed or
/// chosen in it while another tab is shown; only the shown tab takes room
/// on the page. Choosing a tab once the bar is at the top starts the new
/// tab from its beginning rather than part-way down.
class ModuleWorkspace extends StatefulWidget {
  const ModuleWorkspace({
    super.key,
    required this.header,
    required this.labels,
    required this.selected,
    required this.onSelect,
    required this.tabBuilder,
  });

  /// What scrolls away above the tabs: the band, the figures, a notice.
  final List<Widget> header;

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  /// Builds tab [index]. Tab roots are plain columns: the page scrolls.
  final IndexedWidgetBuilder tabBuilder;

  @override
  State<ModuleWorkspace> createState() => _ModuleWorkspaceState();
}

class _ModuleWorkspaceState extends State<ModuleWorkspace> {
  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  final _tabsKey = GlobalKey();
  final _opened = <int>{};

  static const _contentPadding = EdgeInsets.only(top: FarmSpacing.md, bottom: FarmSpacing.lg);

  @override
  void didUpdateWidget(ModuleWorkspace old) {
    super.didUpdateWidget(old);
    // Chosen from elsewhere on the page — a band button, a dashboard card.
    if (old.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toTabStart());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Where the tab bar reaches the top of the screen.
  double get _tabsAt => _headerKey.currentContext?.size?.height ?? 0;

  void _toTabStart() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final top = _tabsAt.clamp(0.0, position.maxScrollExtent);
    if (position.pixels > top) _scroll.jumpTo(top);
  }

  void _select(int index) {
    _toTabStart();
    widget.onSelect(index);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected.clamp(0, widget.labels.length - 1);
    _opened.add(selected);
    final opened = _opened.where((i) => i < widget.labels.length).toList()..sort();
    // A short tab still fills the screen under the tab bar, so the bar
    // stays at the top when moving from a long tab to a short one instead
    // of jumping back down the page.
    return LayoutBuilder(builder: (context, viewport) {
      // The bar's height as last laid out (taller with large text).
      final bar = _tabsKey.currentContext?.findRenderObject() as RenderBox?;
      final tabsHeight = bar != null && bar.hasSize ? bar.size.height : kFarmTouchTarget + 1;
      final minContent = viewport.maxHeight.isFinite ? viewport.maxHeight - tabsHeight - _contentPadding.vertical : 0.0;
      return _page(selected, opened, minContent < 0 ? 0.0 : minContent);
    });
  }

  Widget _page(int selected, List<int> opened, double minContent) {
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            key: _headerKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...widget.header, const SizedBox(height: FarmSpacing.sm)],
          ),
        ),
        PinnedHeaderSliver(
          child: ColoredBox(
            key: _tabsKey,
            color: FarmColors.stone,
            child: UnderlineTabs(labels: widget.labels, selected: selected, onSelect: _select),
          ),
        ),
        SliverPadding(
          padding: _contentPadding,
          sliver: SliverToBoxAdapter(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minContent),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final i in opened)
                    Visibility(
                      key: ValueKey('module-tab-$i'),
                      visible: i == selected,
                      maintainState: true,
                      child: Builder(builder: (context) => widget.tabBuilder(context, i)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
