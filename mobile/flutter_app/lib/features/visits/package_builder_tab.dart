import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../providers/visits_provider.dart';

/// Package Builder (tech spec v0.6 §6, screen 3). Every package is created
/// here dynamically — nothing is a fixed catalog entry (RULE-VIS-010).
class PackageBuilderTab extends StatefulWidget {
  const PackageBuilderTab({super.key});

  @override
  State<PackageBuilderTab> createState() => _PackageBuilderTabState();
}

class _PackageBuilderTabState extends State<PackageBuilderTab> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _basePrice = TextEditingController(text: '0');
  final _duration = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _basePrice.dispose();
    _duration.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<VisitsProvider>().createPackage(
          name: _name.text.trim(),
          description: _description.text.trim().isEmpty ? null : _description.text.trim(),
          basePrice: double.tryParse(_basePrice.text) ?? 0,
          durationMinutes: int.tryParse(_duration.text),
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _name.clear();
        _description.clear();
        _basePrice.text = '0';
        _duration.clear();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Package created.')));
      } else {
        _error = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final packages = context.watch<VisitsProvider>().packages;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'New Package',
            subtitle: 'Base price is per guest — a booking\'s package revenue = base price × guest count.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(flex: 2, child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Package name'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _basePrice, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Base price per guest (\$)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _duration, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (min)'))),
                ]),
                const SizedBox(height: 12),
                TextField(controller: _description, decoration: const InputDecoration(labelText: 'Description'), maxLines: 2),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Create Package'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Packages',
            child: packages.isEmpty
                ? Text('No packages yet.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Name', 'Base price', 'Duration', 'Status'],
                    columnFlex: const [2, 1, 1, 1],
                    rows: [
                      for (final p in packages)
                        [
                          Text(p.name, style: FarmTypography.textTheme.titleSmall),
                          Text('\$${p.basePrice.toStringAsFixed(2)} / guest'),
                          Text(p.durationMinutes != null ? '${p.durationMinutes} min' : '—'),
                          Text(p.active ? 'Active' : 'Inactive'),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
