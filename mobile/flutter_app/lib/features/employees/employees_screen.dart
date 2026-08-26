import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/employee.dart';
import '../../providers/access_provider.dart';
import '../../providers/employees_provider.dart';
import 'audit_history_screen.dart';
import 'employee_form.dart';
import 'permission_matrix.dart';

/// Settings > Employees & Responsibilities (tech spec §8/§9).
///
/// The farm manager's control panel: create staff accounts, decide which
/// areas of the farm each one is responsible for, and review who changed
/// what. Every action here is permission-gated on the Employees module,
/// and the backend re-checks each one.
class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  bool _includeInactive = false;
  bool _loadedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedOnce) return;
    _loadedOnce = true;
    // The roster is manager-only data, so it is fetched when this screen
    // is first shown rather than for every user at sign-in.
    Future.microtask(() => context.read<EmployeesProvider>().load(includeInactive: _includeInactive));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EmployeesProvider>();
    final access = context.watch<AccessProvider>();
    final canCreate = access.canCreate(FarmModule.employees);
    final canViewAudit = access.canView(FarmModule.reports);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.t('employeesAndResponsibilities'), style: FarmTypography.display(size: 28)),
                    const SizedBox(height: 2),
                    Text(context.t('employeesSubtitle'), style: FarmTypography.textTheme.bodyMedium),
                  ],
                ),
              ),
              if (canViewAudit)
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AuditHistoryScreen()),
                  ),
                  icon: const Icon(Icons.history, size: 17),
                  label: Text(context.t('auditHistory')),
                ),
              if (canCreate) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => showEmployeeForm(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(context.t('addEmployee')),
                ),
              ],
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          Row(children: [
            FilterChip(
              label: Text(context.t('showInactive')),
              selected: _includeInactive,
              onSelected: (v) {
                setState(() => _includeInactive = v);
                context.read<EmployeesProvider>().load(includeInactive: v);
              },
            ),
            const Spacer(),
            Text('${provider.employees.length} ${context.t('accounts')}', style: FarmTypography.textTheme.bodySmall),
          ]),
          const SizedBox(height: FarmSpacing.md),
          if (provider.loading && provider.employees.isEmpty)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (provider.error != null)
            SectionCard(child: Text(provider.error!, style: const TextStyle(color: FarmColors.danger)))
          else if (provider.employees.isEmpty)
            SectionCard(child: Text(context.t('noEmployeesYet'), style: FarmTypography.textTheme.bodyMedium))
          else
            LayoutBuilder(builder: (context, c) {
              final columns = c.maxWidth > 1180 ? 3 : (c.maxWidth > 720 ? 2 : 1);
              final width = (c.maxWidth - FarmSpacing.md * (columns - 1)) / columns;
              return Wrap(
                spacing: FarmSpacing.md,
                runSpacing: FarmSpacing.md,
                children: [
                  for (final employee in provider.employees)
                    SizedBox(width: width, child: _EmployeeCard(employee: employee)),
                ],
              );
            }),
        ],
      ),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  const _EmployeeCard({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final canEdit = access.canEdit(FarmModule.employees);
    final canAssign = access.canAssign(FarmModule.employees);
    final canDelete = access.canDelete(FarmModule.employees);

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: employee.active ? FarmColors.gold : FarmColors.mist,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(employee.initials,
                    style: FarmTypography.textTheme.titleMedium?.copyWith(color: FarmColors.ink)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(employee.name, style: FarmTypography.textTheme.titleSmall),
                  Text(employee.jobTitle ?? employee.role.replaceAll('_', ' '),
                      style: FarmTypography.textTheme.bodySmall),
                ],
              ),
            ),
            if (!employee.active)
              StatusPill(label: context.t('inactive'), level: FarmStatusLevel.neutral, dense: true)
            else if (employee.employmentStatus != 'active')
              StatusPill(label: employee.employmentStatus.replaceAll('_', ' '), level: FarmStatusLevel.watch, dense: true),
          ]),
          const SizedBox(height: 10),
          if (employee.email != null)
            Row(children: [
              const Icon(Icons.mail_outline, size: 13, color: FarmColors.muted),
              const SizedBox(width: 6),
              Expanded(child: Text(employee.email!, style: FarmTypography.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
            ]),
          if (employee.phone != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(children: [
                const Icon(Icons.phone_outlined, size: 13, color: FarmColors.muted),
                const SizedBox(width: 6),
                Text(employee.phone!, style: FarmTypography.textTheme.bodySmall),
              ]),
            ),
          const Divider(height: 18, color: FarmColors.border),
          Text(context.t('responsibleFor'), style: const TextStyle(fontSize: 10.5, color: FarmColors.muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (employee.fullAccess)
            StatusPill(label: context.t('allModulesFullControl'), level: FarmStatusLevel.good, dense: true)
          else if (employee.permissions.isEmpty)
            Text(context.t('noModulesAssigned'), style: FarmTypography.textTheme.bodySmall)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final permission in employee.permissions)
                  StatusPill(
                    label: access.moduleLabel(permission.moduleCode, language),
                    level: permission.canEdit ? FarmStatusLevel.good : FarmStatusLevel.neutral,
                    dense: true,
                  ),
              ],
            ),
          const SizedBox(height: FarmSpacing.sm),
          Wrap(spacing: 8, children: [
            if (canEdit)
              OutlinedButton.icon(
                onPressed: () => showEmployeeForm(context, employee: employee),
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: Text(context.t('edit')),
              ),
            if (canAssign && !employee.fullAccess)
              OutlinedButton.icon(
                onPressed: () => showPermissionMatrix(context, employee),
                icon: const AppIcon(FarmIcon.check, size: 15),
                label: Text(context.t('responsibilities')),
              ),
            if (canDelete && employee.active)
              TextButton(
                onPressed: () => _confirmDeactivate(context, employee),
                child: Text(context.t('deactivate'), style: const TextStyle(color: FarmColors.danger)),
              ),
          ]),
        ],
      ),
    );
  }

  Future<void> _confirmDeactivate(BuildContext context, Employee employee) async {
    final provider = context.read<EmployeesProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('deactivateEmployee')),
        content: Text(dialogContext.t('deactivateExplainer').replaceAll('{name}', employee.name)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(dialogContext.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: FarmColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t('deactivate')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await provider.deactivate(employee.id);
    if (!context.mounted || result.success) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error!)));
  }
}
