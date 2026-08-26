import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/task.dart';
import '../../domain/entities/user_profile.dart';
import '../../providers/tasks_provider.dart';

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
          Text(context.t('navTasks'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text(
            user.isManager ? 'Review, create and assign tasks for the team.' : 'Your tasks — tap one to mark it done.',
            style: FarmTypography.textTheme.bodyMedium,
          ),
          const SizedBox(height: FarmSpacing.md),
          _NewTaskForm(user: user, roster: provider.roster),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Open (${open.length})',
            child: Column(children: [for (final t in open) _TaskTile(task: t, user: user, roster: provider.roster), if (open.isEmpty) const _EmptyState(label: 'Nothing open — great work!')]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Completed (${done.length})',
            child: Column(children: [for (final t in done) _TaskTile(task: t, user: user, roster: provider.roster), if (done.isEmpty) const _EmptyState(label: 'No tasks completed yet.')]),
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
      setState(() => _error = 'Give the task a title.');
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
      title: 'New Task',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(flex: 2, child: TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title'))),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: TextField(controller: _description, decoration: const InputDecoration(labelText: 'Description (optional)'))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            if (widget.user.isManager) ...[
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _assignedTo,
                  decoration: const InputDecoration(labelText: 'Assign to'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Myself')),
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
                decoration: const InputDecoration(labelText: 'Priority'),
                items: const [DropdownMenuItem(value: 'high', child: Text('High')), DropdownMenuItem(value: 'medium', child: Text('Medium')), DropdownMenuItem(value: 'low', child: Text('Low'))],
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
                child: Text(_dueAt == null ? 'Due date' : '${_dueAt!.day}/${_dueAt!.month} ${TimeOfDay.fromDateTime(_dueAt!).format(context)}'),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add'),
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
              Text(task.title, style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: done ? TextDecoration.lineThrough : null)),
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
            tooltip: 'Reassign',
            icon: const Icon(Icons.more_vert, size: 18, color: FarmColors.muted),
            onSelected: (value) {
              if (value == 'delete') {
                context.read<TasksProvider>().remove(task.id);
              } else {
                context.read<TasksProvider>().reassign(taskId: task.id, assignedTo: value);
              }
            },
            itemBuilder: (context) => [
              for (final u in roster) PopupMenuItem(value: u.id, child: Text('Assign to ${u.name}')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'delete', child: Text('Delete task')),
            ],
          ),
        ],
      ]),
    );
  }
}
