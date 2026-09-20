import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/task.dart';
import '../../domain/entities/user_profile.dart';
import '../../features/sync/sync_pill.dart';
import '../../providers/tasks_provider.dart';
import '../../sync/sync_controller.dart';

/// Tasks list + assignment (tech spec §6 nav table: "Assign, complete, and
/// follow up"). A farm manager sees every task on the farm, can create one
/// and assign it to any employee, and can reassign or delete an existing
/// one; an employee sees only their own (and unassigned) tasks and can
/// only create a task for themself — the backend enforces the same split
/// (see `api/deps.py`/`api/v1/tasks.py`), this screen just doesn't offer
/// the controls a 403 would come back from anyway.
class TasksScreen extends StatelessWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<SessionController>().user!;
    final provider = context.watch<TasksProvider>();
    final visible = user.isManager ? provider.tasks : provider.tasks.where((t) => t.assignedTo == null || t.assignedTo == user.id).toList();
    final open = visible.where((t) => t.status != TaskStatus.done).toList();
    final done = visible.where((t) => t.status == TaskStatus.done).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HeroBand(
            title: context.t('navTasks'),
            subtitle: user.isManager ? context.t('tasksSubtitleManager') : context.t('tasksSubtitleWorker'),
            icon: FarmIcon.task,
          ),
          const SizedBox(height: FarmSpacing.md),
          _NewTaskForm(user: user, roster: provider.roster),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: '${context.t('openTasks')} (${open.length})',
            child: Column(children: [for (final t in open) _TaskTile(task: t, user: user, roster: provider.roster), if (open.isEmpty) _EmptyState(label: context.t('nothingOpen'))]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: '${context.t('completedTasks')} (${done.length})',
            child: Column(children: [for (final t in done) _TaskTile(task: t, user: user, roster: provider.roster), if (done.isEmpty) _EmptyState(label: context.t('noTasksCompleted'))]),
          ),
        ],
      ),
    );
  }
}

class _NewTaskForm extends StatefulWidget {
  const _NewTaskForm({required this.user, required this.roster});
  final UserProfile user;
  final List<UserProfile> roster;

  @override
  State<_NewTaskForm> createState() => _NewTaskFormState();
}

class _NewTaskFormState extends State<_NewTaskForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  String? _assignedTo;
  String _priority = 'medium';
  DateTime? _dueAt;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = context.t('taskTitleRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<TasksProvider>().createTask(
          title: _title.text.trim(),
          description: _description.text.trim().isEmpty ? null : _description.text.trim(),
          assignedTo: widget.user.isManager ? _assignedTo : widget.user.id,
          dueAt: _dueAt,
          priority: _priority,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _title.clear();
        _description.clear();
        _assignedTo = null;
        _priority = 'medium';
        _dueAt = null;
      } else {
        _error = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('newTask'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(flex: 2, child: TextField(controller: _title, decoration: InputDecoration(labelText: context.t('taskTitle')))),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: TextField(controller: _description, decoration: InputDecoration(labelText: context.t('notes')))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            if (widget.user.isManager) ...[
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _assignedTo,
                  decoration: InputDecoration(labelText: context.t('assignTo')),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text(context.t('myself'))),
                    for (final u in widget.roster.where((u) => u.id != widget.user.id)) DropdownMenuItem<String?>(value: u.id, child: Text('${u.name}${u.department != null ? ' · ${u.department}' : ''}')),
                  ],
                  onChanged: (v) => setState(() => _assignedTo = v),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _priority,
                decoration: InputDecoration(labelText: context.t('priority')),
                items: [DropdownMenuItem(value: 'high', child: Text(context.t('high'))), DropdownMenuItem(value: 'medium', child: Text(context.t('medium'))), DropdownMenuItem(value: 'low', child: Text(context.t('low')))],
                onChanged: (v) => setState(() => _priority = v ?? _priority),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(context: context, initialDate: _dueAt ?? now, firstDate: now.subtract(const Duration(days: 1)), lastDate: now.add(const Duration(days: 365)));
                  if (picked == null || !mounted) return;
                  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_dueAt ?? now));
                  setState(() => _dueAt = DateTime(picked.year, picked.month, picked.day, time?.hour ?? 17, time?.minute ?? 0));
                },
                child: Text(_dueAt == null ? context.t('dueDate') : '${_dueAt!.day}/${_dueAt!.month} ${TimeOfDay.fromDateTime(_dueAt!).format(context)}'),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('add')),
            ),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ],
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
  const _TaskTile({required this.task, required this.user, required this.roster});
  final FarmTask task;
  final UserProfile user;
  final List<UserProfile> roster;

  String? _nameFor(String? userId) {
    if (userId == null) return null;
    for (final u in roster) {
      if (u.id == userId) return u.name;
    }
    return userId;
  }

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    final level = switch (task.priority) {
      TaskPriority.high => FarmStatusLevel.alert,
      TaskPriority.medium => FarmStatusLevel.watch,
      TaskPriority.low => FarmStatusLevel.neutral,
    };
    final assigneeName = _nameFor(task.assignedTo);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        InkWell(
          onTap: () => context.read<TasksProvider>().toggle(task.id),
          child: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? FarmColors.success : FarmColors.muted, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                    task.title,
                    style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: done ? TextDecoration.lineThrough : null),
                  ),
                ),
                if (context.watch<SyncController>().isPending(task.id)) ...[
                  const SizedBox(width: 8),
                  const PendingChip(),
                ],
              ]),
              Text(
                user.isManager && assigneeName != null ? '${task.category} · $assigneeName' : task.category,
                style: FarmTypography.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (!done) StatusPill(label: task.priority.name, level: level, dense: true),
        const SizedBox(width: 10),
        Text(TimeOfDay.fromDateTime(task.dueAt).format(context), style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
        if (user.isManager) ...[
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: context.t('reassign'),
            icon: const Icon(Icons.more_vert, size: 18, color: FarmColors.muted),
            onSelected: (value) {
              if (value == 'delete') {
                context.read<TasksProvider>().remove(task.id);
              } else {
                context.read<TasksProvider>().reassign(taskId: task.id, assignedTo: value);
              }
            },
            itemBuilder: (context) => [
              for (final u in roster) PopupMenuItem(value: u.id, child: Text(context.t('assignToName').replaceFirst('{name}', u.name))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'delete', child: Text(context.t('deleteTask'))),
            ],
          ),
        ],
      ]),
    );
  }
}
