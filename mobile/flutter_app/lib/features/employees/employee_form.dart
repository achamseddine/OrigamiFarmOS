import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/employee.dart';
import '../../providers/employees_provider.dart';

/// Create or edit an employee record (tech spec §8).
void showEmployeeForm(BuildContext context, {Employee? employee}) {
  showDialog<void>(context: context, builder: (_) => _EmployeeFormDialog(employee: employee));
}

class _EmployeeFormDialog extends StatefulWidget {
  const _EmployeeFormDialog({this.employee});
  final Employee? employee;

  @override
  State<_EmployeeFormDialog> createState() => _EmployeeFormDialogState();
}

class _EmployeeFormDialogState extends State<_EmployeeFormDialog> {
  late final _name = TextEditingController(text: widget.employee?.name ?? '');
  late final _email = TextEditingController(text: widget.employee?.email ?? '');
  late final _phone = TextEditingController(text: widget.employee?.phone ?? '');
  late final _jobTitle = TextEditingController(text: widget.employee?.jobTitle ?? '');
  late final _workingHours = TextEditingController(text: widget.employee?.workingHours ?? '');
  late final _notes = TextEditingController(text: widget.employee?.notes ?? '');
  final _password = TextEditingController();

  late String _role = widget.employee?.role ?? 'worker';
  late String _employmentStatus = widget.employee?.employmentStatus ?? 'active';
  late String? _department = widget.employee?.department;
  late DateTime? _startDate = widget.employee?.startDate;
  late Set<String> _workingDays = {...?widget.employee?.workingDays};

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.employee != null;

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _jobTitle, _workingHours, _notes, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = context.t('nameRequired'));
      return;
    }
    if (!_isEdit && _password.text.length < 8) {
      setState(() => _error = context.t('passwordTooShort'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final provider = context.read<EmployeesProvider>();
    final result = _isEdit
        ? await provider.updateEmployee(widget.employee!.id, {
            'name': _name.text.trim(),
            'email': _blankToNull(_email.text),
            'phone': _blankToNull(_phone.text),
            'role': _role,
            'department': _department,
            'job_title': _blankToNull(_jobTitle.text),
            'employment_status': _employmentStatus,
            'start_date': _startDate?.toIso8601String(),
            'working_days': _workingDays.toList(),
            'working_hours': _blankToNull(_workingHours.text),
            'notes': _blankToNull(_notes.text),
            // Only sent when the manager actually typed a new one, so an
            // edit never silently resets someone's password.
            if (_password.text.isNotEmpty) 'password': _password.text,
          })
        : await provider.createEmployee(
            name: _name.text.trim(),
            password: _password.text,
            email: _blankToNull(_email.text),
            phone: _blankToNull(_phone.text),
            role: _role,
            department: _department,
            jobTitle: _blankToNull(_jobTitle.text),
            employmentStatus: _employmentStatus,
            startDate: _startDate,
            workingDays: _workingDays.isEmpty ? null : _workingDays.toList(),
            workingHours: _blankToNull(_workingHours.text),
            notes: _blankToNull(_notes.text),
          );

    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isEdit ? context.t('employeeUpdated') : context.t('employeeCreated'))),
      );
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  String? _blankToNull(String value) => value.trim().isEmpty ? null : value.trim();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.lg, FarmSpacing.sm, 0),
              child: Row(children: [
                Expanded(
                  child: Text(_isEdit ? context.t('editEmployee') : context.t('addEmployee'),
                      style: FarmTypography.display(size: 22)),
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
                    _sectionLabel(context, 'identity'),
                    Row(children: [
                      Expanded(child: TextField(controller: _name, decoration: InputDecoration(labelText: context.t('fullName')))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _jobTitle, decoration: InputDecoration(labelText: context.t('jobTitle')))),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(labelText: context.t('emailForLogin')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _phone, decoration: InputDecoration(labelText: context.t('phone')))),
                    ]),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: _isEdit ? context.t('newPasswordOptional') : context.t('password'),
                        helperText: context.t('passwordHelper'),
                      ),
                    ),
                    const SizedBox(height: FarmSpacing.md),
                    _sectionLabel(context, 'employment'),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _role,
                          decoration: InputDecoration(labelText: context.t('role')),
                          items: [
                            for (final role in kAssignableRoles)
                              DropdownMenuItem(value: role, child: Text(role.replaceAll('_', ' '))),
                          ],
                          onChanged: (v) => setState(() => _role = v ?? _role),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _employmentStatus,
                          decoration: InputDecoration(labelText: context.t('employmentStatus')),
                          items: [
                            for (final status in kEmploymentStatuses)
                              DropdownMenuItem(value: status, child: Text(status.replaceAll('_', ' '))),
                          ],
                          onChanged: (v) => setState(() => _employmentStatus = v ?? _employmentStatus),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      _role == 'manager' ? context.t('managerRoleExplainer') : context.t('roleExplainer'),
                      style: const TextStyle(fontSize: 11, color: FarmColors.muted),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          value: _department,
                          decoration: InputDecoration(
                            labelText: context.t('startingArea'),
                            helperText: _isEdit ? null : context.t('startingAreaHelper'),
                          ),
                          items: [
                            DropdownMenuItem<String?>(value: null, child: Text(context.t('noneChooseModulesLater'))),
                            for (final dept in const ['animals', 'produce', 'mouneh', 'visits'])
                              DropdownMenuItem<String?>(value: dept, child: Text(context.t('dept_$dept'))),
                          ],
                          onChanged: (v) => setState(() => _department = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _startDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) setState(() => _startDate = picked);
                          },
                          child: Text(_startDate == null
                              ? context.t('startDate')
                              : '${_startDate!.day}/${_startDate!.month}/${_startDate!.year}'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: FarmSpacing.md),
                    _sectionLabel(context, 'schedule'),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final day in kWeekdays)
                          FilterChip(
                            label: Text(context.t('day_$day')),
                            selected: _workingDays.contains(day),
                            onSelected: (on) => setState(() => on ? _workingDays.add(day) : _workingDays.remove(day)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _workingHours,
                      decoration: InputDecoration(labelText: context.t('workingHours'), hintText: '07:00-15:00'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _notes,
                      maxLines: 2,
                      decoration: InputDecoration(labelText: context.t('notes')),
                    ),
                    const SizedBox(height: FarmSpacing.md),
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
                if (!_isEdit)
                  Expanded(
                    child: Text(context.t('newEmployeeNextStep'), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                  )
                else
                  const Spacer(),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit ? context.t('saveChanges') : context.t('createEmployee')),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String key) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          context.t(key),
          style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4),
        ),
      );
}
