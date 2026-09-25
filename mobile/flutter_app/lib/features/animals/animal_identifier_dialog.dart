import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../providers/livestock_provider.dart';

/// Adds an identifier to an existing animal (generic animal model §4): a
/// replacement ear tag, a passport that arrived after registration, an
/// RFID fitted at weighing. The types offered are the ones the animal's
/// capabilities allow — a horse is not offered an ear tag here either.
///
/// Returns true when one was added, so the caller can refresh the record.
Future<bool> showAddIdentifierDialog(BuildContext context, {required Animal animal, required CapabilitySet caps}) async {
  final added = await showDialog<bool>(
    context: context,
    builder: (_) => _AddIdentifierDialog(animal: animal, caps: caps),
  );
  return added ?? false;
}

class _AddIdentifierDialog extends StatefulWidget {
  const _AddIdentifierDialog({required this.animal, required this.caps});
  final Animal animal;
  final CapabilitySet caps;

  @override
  State<_AddIdentifierDialog> createState() => _AddIdentifierDialogState();
}

class _AddIdentifierDialogState extends State<_AddIdentifierDialog> {
  final _value = TextEditingController();
  final _authority = TextEditingController();
  late String _type = _initialType();
  bool _primary = false;
  bool _saving = false;
  String? _error;

  List<String> get _types {
    final allowed = widget.caps.allowedIdentifierTypes.toSet();
    final offered = [
      for (final t in IdentifierType.fieldOrder)
        if (allowed.contains(t)) t,
    ];
    // An animal whose capabilities are not known yet (registered offline a
    // moment ago) can still be given a farm number or a name.
    return offered.isEmpty ? IdentifierType.alwaysAllowed.where((t) => t != IdentifierType.name).toList() : offered;
  }

  /// A required type the animal is still missing comes first — that is
  /// almost always why someone opened this dialog.
  String _initialType() {
    final present = {for (final i in widget.animal.activeIdentifiers) i.type};
    for (final t in widget.caps.requiredIdentifierTypes) {
      if (!present.contains(t)) return t;
    }
    return _types.first;
  }

  @override
  void dispose() {
    _value.dispose();
    _authority.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_value.text.trim().isEmpty) {
      setState(() => _error = context.t('identifierValueRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final authority = _authority.text.trim();
    final result = await context.read<LivestockProvider>().addIdentifier(
          widget.animal.id,
          AnimalIdentifier(
            id: '',
            type: _type,
            value: _value.text.trim(),
            issuingAuthority: authority.isEmpty ? null : authority,
            isPrimary: _primary,
            status: 'active',
          ),
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('identifierAdded'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final types = _types;
    return AlertDialog(
      title: Text('${context.t('addIdentifier')} — ${widget.animal.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: types.contains(_type) ? _type : types.first,
              decoration: InputDecoration(labelText: context.t('identifierType')),
              items: [for (final t in types) DropdownMenuItem(value: t, child: Text(context.t('id_$t')))],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              autofocus: true,
              decoration: InputDecoration(labelText: context.t('identifierValue')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _authority,
              decoration: InputDecoration(labelText: context.t('issuingAuthority')),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _primary,
              title: Text(context.t('makePrimary')),
              onChanged: (v) => setState(() => _primary = v ?? false),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('add')),
        ),
      ],
    );
  }
}
