import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/employee.dart';
import '../../providers/access_provider.dart';
import '../../providers/employees_provider.dart';

/// The responsibility matrix (tech spec §9/§11).
///
/// One row per module the farm has, one switch per action. Assigning
/// Animals + Agriculture to the same person is two taps; giving them
/// create-and-edit on one and view-only on the other is two more. There is
/// no fixed "Cow Worker" role to pick from, because the point is that a
/// farm decides its own combinations.
void showPermissionMatrix(BuildContext context, Employee employee) {
  showDialog<void>(context: context, builder: (_) => _PermissionMatrixDialog(employee: employee));
}

class _PermissionMatrixDialog extends StatefulWidget {
  const _PermissionMatrixDialog({required this.employee});
  final Employee employee;

  @override
  State<_PermissionMatrixDialog> createState() => _PermissionMatrixDialogState();
}

class _PermissionMatrixDialogState extends State<_PermissionMatrixDialog> {
  /// module code -> the grant being edited. Absent means "not responsible
  /// for this module", which is what saving will revoke.
  late final Map<String, ModulePermission> _draft = {
    for (final p in widget.employee.permissions) p.moduleCode: p,
  };
  bool _saving = false;
  String? _error;

  static const _actions = [
    (PermissionAction.view, 'permView'),
    (PermissionAction.create, 'permCreate'),
    (PermissionAction.edit, 'permEdit'),
    (PermissionAction.delete, 'permDelete'),
    (PermissionAction.approve, 'permApprove'),
    (PermissionAction.export, 'permExport'),
    (PermissionAction.assign, 'permAssign'),
    (PermissionAction.configure, 'permConfigure'),
  ];

  void _toggleModule(String code, bool on) {
    setState(() {
      if (on) {
        _draft[code] = ModulePermission.defaultFor(code);
      } else {
        _draft.remove(code);
      }
    });
  }

  void _toggleAction(String code, String action, bool value) {
    final current = _draft[code];
    if (current == null) return;
    setState(() {
      // View is what the module grant means — turning it off is the same
      // as not being responsible for the module at all.
      if (action == PermissionAction.view && !value) {
        _draft.remove(code);
        return;
      }
      var next = current.withAction(action, value);
      // Any action beyond view implies being able to see it, so granting
      // "create" cannot leave the employee unable to open the screen.
      if (value && action != PermissionAction.view) {
        next = next.withAction(PermissionAction.view, true);
      }
      _draft[code] = next;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<EmployeesProvider>().setPermissions(
          widget.employee.id,
          _draft.values.toList(),
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final catalog = access.catalog;

    // Group by area so a long catalog stays readable.
    final groups = <String, List<ModuleCatalogEntry>>{};
    for (final module in catalog) {
      groups.putIfAbsent(module.group, () => []).add(module);
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.lg, FarmSpacing.sm, 0),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.t('responsibilitiesFor').replaceAll('{name}', widget.employee.name),
                          style: FarmTypography.display(size: 21)),
                      const SizedBox(height: 2),
                      Text(context.t('permissionMatrixSubtitle'), style: FarmTypography.textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 20, color: FarmColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final group in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 6),
                        child: Text(
                          context.t('moduleGroup_${group.key}'),
                          style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4),
                        ),
                      ),
                      for (final module in group.value)
                        _ModuleRow(
                          module: module,
                          language: language,
                          permission: _draft[module.code],
                          actions: _actions,
                          onToggleModule: (on) => _toggleModule(module.code, on),
                          onToggleAction: (action, value) => _toggleAction(module.code, action, value),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                child: Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
              ),
            const Divider(height: 20, color: FarmColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg),
              child: Row(children: [
                Text(
                  '${_draft.length} ${context.t(_draft.length == 1 ? 'moduleSingular' : 'modulePlural')}',
                  style: FarmTypography.textTheme.bodySmall,
                ),
                const Spacer(),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(context.t('saveResponsibilities')),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
    required this.module,
    required this.language,
    required this.permission,
    required this.actions,
    required this.onToggleModule,
    required this.onToggleAction,
  });

  final ModuleCatalogEntry module;
  final String language;
  final ModulePermission? permission;
  final List<(String, String)> actions;
  final ValueChanged<bool> onToggleModule;
  final void Function(String action, bool value) onToggleAction;

  @override
  Widget build(BuildContext context) {
    final assigned = permission != null;
    final unlicensed = !module.licensedActive;

    return Opacity(
      opacity: unlicensed ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: assigned ? FarmColors.tint(FarmColors.cedar, 0.05) : Colors.transparent,
          borderRadius: BorderRadius.circular(FarmRadii.sm),
          border: Border.all(color: assigned ? FarmColors.cedar.withOpacity(0.4) : FarmColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Switch(
                value: assigned,
                // A module the farm has not licensed cannot be assigned —
                // the grant would be dead weight until it is bought.
                onChanged: unlicensed ? null : onToggleModule,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(module.label(language), style: FarmTypography.textTheme.titleSmall),
                    if (unlicensed)
                      Text(context.t('moduleNotLicensed'), style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
                  ],
                ),
              ),
            ]),
            if (assigned) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 52),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 2,
                  children: [
                    for (final action in actions)
                      _ActionToggle(
                        label: context.t(action.$2),
                        value: permission!.byAction(action.$1),
                        onChanged: (v) => onToggleAction(action.$1, v),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionToggle extends StatelessWidget {
  const _ActionToggle({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(FarmRadii.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
