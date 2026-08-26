import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../domain/entities/notification.dart';
import '../../providers/access_provider.dart';
import '../../providers/notifications_provider.dart';
import 'priority_card.dart';

/// The full Today's Priorities view behind "Expand" (tech spec §5).
///
/// Priorities are not just alerts here: the same list carries the farm's
/// open tasks, inventory warnings, veterinary follow-ups, harvest
/// reminders, visitor appointments and Mouneh production work, filtered by
/// urgency, module and who they belong to.
class PrioritiesScreen extends StatefulWidget {
  const PrioritiesScreen({super.key});

  @override
  State<PrioritiesScreen> createState() => _PrioritiesScreenState();
}

class _PrioritiesScreenState extends State<PrioritiesScreen> {
  String? _priorityFilter;
  String? _moduleFilter;
  String? _kindFilter;
  String? _assignmentFilter;

  List<FarmPriority>? _results;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await context.read<NotificationsProvider>().fetchPriorities(
            module: _moduleFilter,
            priority: _priorityFilter,
            kind: _kindFilter,
            assignment: _assignmentFilter,
          );
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load priorities.';
        _loading = false;
      });
    }
  }

  void _setFilter(void Function() change) {
    setState(change);
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NotificationsProvider>();
    final access = context.watch<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final counts = provider.countsByPriority;

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.xl, vertical: FarmSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(context.t('back')),
                ),
                const Spacer(),
                IconButton(onPressed: _fetch, icon: const Icon(Icons.refresh), tooltip: context.t('refresh')),
              ]),
              Row(children: [
                const AppIcon(FarmIcon.warning, size: 22, color: FarmColors.cedar),
                const SizedBox(width: 8),
                Text(context.t('todaysPriorities'), style: FarmTypography.display(size: 26)),
              ]),
              const SizedBox(height: 2),
              Text(context.t('prioritiesSubtitle'), style: FarmTypography.textTheme.bodyMedium),
              const SizedBox(height: FarmSpacing.md),
              _FilterBar(
                priorityFilter: _priorityFilter,
                moduleFilter: _moduleFilter,
                kindFilter: _kindFilter,
                assignmentFilter: _assignmentFilter,
                counts: counts,
                modules: provider.modulesInFeed,
                moduleLabel: (code) => access.moduleLabel(code, language),
                onPriority: (v) => _setFilter(() => _priorityFilter = v),
                onModule: (v) => _setFilter(() => _moduleFilter = v),
                onKind: (v) => _setFilter(() => _kindFilter = v),
                onAssignment: (v) => _setFilter(() => _assignmentFilter = v),
              ),
              const SizedBox(height: FarmSpacing.md),
              Expanded(child: _body(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: FarmColors.danger)));
    }
    final results = _results ?? const <FarmPriority>[];
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppIcon(FarmIcon.check, size: 32, color: FarmColors.success),
            const SizedBox(height: 10),
            Text(context.t('nothingMatchesFilters'), style: FarmTypography.textTheme.bodyMedium),
          ],
        ),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      final columns = c.maxWidth > 1180 ? 3 : (c.maxWidth > 760 ? 2 : 1);
      final width = (c.maxWidth - FarmSpacing.md * (columns - 1)) / columns;
      return SingleChildScrollView(
        child: Wrap(
          spacing: FarmSpacing.md,
          runSpacing: FarmSpacing.md,
          children: [
            for (final item in results)
              SizedBox(width: width, child: PriorityCard(priority: item, onChanged: _fetch)),
          ],
        ),
      );
    });
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.priorityFilter,
    required this.moduleFilter,
    required this.kindFilter,
    required this.assignmentFilter,
    required this.counts,
    required this.modules,
    required this.moduleLabel,
    required this.onPriority,
    required this.onModule,
    required this.onKind,
    required this.onAssignment,
  });

  final String? priorityFilter;
  final String? moduleFilter;
  final String? kindFilter;
  final String? assignmentFilter;
  final Map<String, int> counts;
  final List<String> modules;
  final String Function(String) moduleLabel;
  final ValueChanged<String?> onPriority;
  final ValueChanged<String?> onModule;
  final ValueChanged<String?> onKind;
  final ValueChanged<String?> onAssignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(context, context.t('urgency'), [
          _chip(context.t('all'), priorityFilter == null, () => onPriority(null)),
          for (final level in const ['critical', 'high', 'medium', 'low'])
            if ((counts[level] ?? 0) > 0)
              _chip('${context.t(level)} (${counts[level]})', priorityFilter == level, () => onPriority(level)),
        ]),
        const SizedBox(height: 6),
        _row(context, context.t('type'), [
          _chip(context.t('all'), kindFilter == null, () => onKind(null)),
          _chip(context.t('alerts'), kindFilter == 'alert', () => onKind('alert')),
          _chip(context.t('tasks'), kindFilter == 'task', () => onKind('task')),
        ]),
        const SizedBox(height: 6),
        _row(context, context.t('assignment'), [
          _chip(context.t('all'), assignmentFilter == null, () => onAssignment(null)),
          _chip(context.t('assignedToMe'), assignmentFilter == 'me', () => onAssignment('me')),
          _chip(context.t('assignedToTeam'), assignmentFilter == 'team', () => onAssignment('team')),
          _chip(context.t('unassigned'), assignmentFilter == 'unassigned', () => onAssignment('unassigned')),
        ]),
        if (modules.isNotEmpty) ...[
          const SizedBox(height: 6),
          _row(context, context.t('module'), [
            _chip(context.t('all'), moduleFilter == null, () => onModule(null)),
            for (final code in modules) _chip(moduleLabel(code), moduleFilter == code, () => onModule(code)),
          ]),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, String label, List<Widget> chips) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (final chip in chips) Padding(padding: const EdgeInsets.only(right: 6), child: chip)]),
            ),
          ),
        ],
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) =>
      ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap());
}
