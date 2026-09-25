import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/task.dart';
import '../../providers/tasks_provider.dart';

/// Tasks list/calendar (tech spec §6 nav table: "Assign, complete, and
/// follow up"). Not one of the 10 numbered Option C screens, but part of
/// the primary navigation.
class TasksScreen extends StatelessWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tasks = context.watch<TasksProvider>().tasks;
    final open = tasks.where((t) => t.status != TaskStatus.done).toList();
    final done = tasks.where((t) => t.status == TaskStatus.done).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('navTasks'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text('Assign, complete, and follow up on farm tasks.', style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Open (${open.length})',
            child: Column(children: [for (final t in open) _TaskTile(task: t), if (open.isEmpty) const _EmptyState(label: 'Nothing open — great work!')]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Completed (${done.length})',
            child: Column(children: [for (final t in done) _TaskTile(task: t), if (done.isEmpty) const _EmptyState(label: 'No tasks completed yet today.')]),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(label, style: FarmTypography.textTheme.bodySmall),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final FarmTask task;

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    final level = switch (task.priority) {
      TaskPriority.high => FarmStatusLevel.alert,
      TaskPriority.medium => FarmStatusLevel.watch,
      TaskPriority.low => FarmStatusLevel.neutral,
    };
    return InkWell(
      onTap: () => context.read<TasksProvider>().toggle(task.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? FarmColors.success : FarmColors.muted, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title, style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: done ? TextDecoration.lineThrough : null)),
                Text(task.category, style: FarmTypography.textTheme.bodySmall),
              ],
            ),
          ),
          if (!done)
            StatusPill(
              label: task.priority.name,
              level: level,
              dense: true,
            ),
          const SizedBox(width: 10),
          Text(TimeOfDay.fromDateTime(task.dueAt).format(context), style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
        ]),
      ),
    );
  }
}
