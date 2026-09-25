import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';

/// Recipe / Raw Materials Setup (tech spec v0.5 §6, screen 3): the Bill of
/// Materials — ingredients, packaging, labor and optional overhead costs
/// that together define how a product's cost is calculated.
class RecipeSetupTab extends StatefulWidget {
  const RecipeSetupTab({super.key});

  @override
  State<RecipeSetupTab> createState() => _RecipeSetupTabState();
}

class _RecipeItemDraft {
  _RecipeItemDraft({required this.materialId, this.quantity = 1, this.lossPercent = 0});
  String materialId;
  double quantity;
  double lossPercent;
}

class _CostComponentDraft {
  _CostComponentDraft({this.costType = 'labor', this.label = '', this.calculationMethod = 'fixed', this.amount, this.quantity, this.unitCost});
  String costType;
  String label;
  String calculationMethod;
  double? amount;
  double? quantity;
  double? unitCost;
}

class _RecipeSetupTabState extends State<RecipeSetupTab> {
  String? _productId;
  final _basisQuantity = TextEditingController(text: '100');
  final _basisUnit = TextEditingController(text: 'jar');
  final _notes = TextEditingController();
  final List<_RecipeItemDraft> _items = [];
  final List<_CostComponentDraft> _components = [];
  bool _saving = false;
  String? _error;
  String? _savedMessage;

  @override
  void dispose() {
    _basisQuantity.dispose();
    _basisUnit.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    _productId ??= provider.products.isNotEmpty ? provider.products.first.id : null;
    final product = _productId == null ? null : provider.productById(_productId!);
    final existingRecipe = _productId == null ? null : provider.recipeFor(_productId!);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Product',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  value: _productId,
                  decoration: const InputDecoration(labelText: 'Choose a product'),
                  items: [for (final p in provider.products) DropdownMenuItem(value: p.id, child: Text(p.name))],
                  onChanged: provider.products.isEmpty ? null : (v) => setState(() => _productId = v),
                ),
                if (provider.products.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Create a product first on the Product Builder tab.', style: FarmTypography.textTheme.bodySmall)),
                if (existingRecipe != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: StatusPill(label: 'Recipe v${existingRecipe.version} active — saving below creates v${existingRecipe.version + 1}', level: FarmStatusLevel.info, dense: true),
                  ),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Raw Materials Library',
            subtitle: 'Ingredients and packaging, reusable across every product',
            trailing: 'Add material',
            onTrailingTap: () => _showAddMaterialDialog(context),
            child: provider.rawMaterials.isEmpty
                ? Text('No raw materials yet.', style: FarmTypography.textTheme.bodySmall)
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in provider.rawMaterials)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.sm)),
                          child: Text('${m.name} · \$${m.defaultUnitCost.toStringAsFixed(2)}/${m.unit} · ${m.currentStock.toStringAsFixed(0)} in stock', style: FarmTypography.textTheme.bodySmall),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Recipe (Bill of Materials)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: TextField(controller: _basisQuantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'This recipe makes (qty)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _basisUnit, decoration: const InputDecoration(labelText: 'Basis unit'))),
                ]),
                const SizedBox(height: 12),
                for (var i = 0; i < _items.length; i++) _itemRow(context, i, provider),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: provider.rawMaterials.isEmpty ? null : () => setState(() => _items.add(_RecipeItemDraft(materialId: provider.rawMaterials.first.id))),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add ingredient / packaging line'),
                ),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Labor & Optional Costs',
            subtitle: 'Transport, gas/electricity, cooling, market fees, other overhead',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _components.length; i++) _componentRow(context, i),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _components.add(_CostComponentDraft())),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add cost line'),
                ),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes (optional)')),
          const SizedBox(height: FarmSpacing.md),
          Row(children: [
            FilledButton(
              onPressed: (_saving || product == null || _items.isEmpty) ? null : _submit,
              child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save Recipe'),
            ),
            const SizedBox(width: 12),
            if (_error != null) Expanded(child: Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))),
            if (_savedMessage != null) Expanded(child: Text(_savedMessage!, style: const TextStyle(color: FarmColors.success, fontSize: 12.5))),
          ]),
        ],
      ),
    );
  }

  Widget _itemRow(BuildContext context, int i, MounehProvider provider) {
    final draft = _items[i];
    return Padding(
      key: ValueKey(draft),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              value: draft.materialId,
              decoration: const InputDecoration(labelText: 'Material'),
              items: [for (final m in provider.rawMaterials) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: (v) => setState(() => draft.materialId = v ?? draft.materialId),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: draft.quantity.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Qty'),
              onChanged: (v) => draft.quantity = double.tryParse(v) ?? draft.quantity,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: draft.lossPercent.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Loss %'),
              onChanged: (v) => draft.lossPercent = double.tryParse(v) ?? draft.lossPercent,
            ),
          ),
          IconButton(onPressed: () => setState(() => _items.removeAt(i)), icon: const Icon(Icons.close, size: 18)),
        ],
      ),
    );
  }

  Widget _componentRow(BuildContext context, int i) {
    final draft = _components[i];
    final needsQtyRate = draft.calculationMethod == 'quantity_x_rate';
    final needsAmount = draft.calculationMethod == 'fixed' || draft.calculationMethod == 'per_output_unit' || draft.calculationMethod == 'percentage';
    return Padding(
      key: ValueKey(draft),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              value: draft.costType,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final t in kMounehCostTypes) DropdownMenuItem(value: t, child: Text(t.replaceAll('_', ' ')))],
              onChanged: (v) => setState(() => draft.costType = v ?? draft.costType),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(initialValue: draft.label, decoration: const InputDecoration(labelText: 'Label'), onChanged: (v) => draft.label = v),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              value: draft.calculationMethod,
              decoration: const InputDecoration(labelText: 'Method'),
              items: [for (final m in kMounehCalculationMethods) DropdownMenuItem(value: m, child: Text(m.replaceAll('_', ' ')))],
              onChanged: (v) => setState(() => draft.calculationMethod = v ?? draft.calculationMethod),
            ),
          ),
          const SizedBox(width: 8),
          if (needsQtyRate) ...[
            Expanded(child: TextFormField(decoration: const InputDecoration(labelText: 'Qty'), keyboardType: TextInputType.number, onChanged: (v) => draft.quantity = double.tryParse(v))),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(decoration: const InputDecoration(labelText: 'Rate'), keyboardType: TextInputType.number, onChanged: (v) => draft.unitCost = double.tryParse(v))),
          ] else if (needsAmount)
            Expanded(
              child: TextFormField(
                decoration: InputDecoration(labelText: draft.calculationMethod == 'percentage' ? '%' : '\$'),
                keyboardType: TextInputType.number,
                onChanged: (v) => draft.amount = double.tryParse(v),
              ),
            ),
          IconButton(onPressed: () => setState(() => _components.removeAt(i)), icon: const Icon(Icons.close, size: 18)),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
      _savedMessage = null;
    });
    final provider = context.read<MounehProvider>();
    final items = [
      for (final d in _items)
        MounehRecipeItem(
          materialId: d.materialId,
          materialType: provider.materialById(d.materialId)?.category ?? 'raw_material',
          quantity: d.quantity,
          unit: provider.materialById(d.materialId)?.unit ?? '',
          lossPercent: d.lossPercent,
        ),
    ];
    final components = [
      for (final d in _components) MounehCostComponent(costType: d.costType, label: d.label.isEmpty ? d.costType : d.label, calculationMethod: d.calculationMethod, amount: d.amount, quantity: d.quantity, unitCost: d.unitCost),
    ];
    final result = await provider.createRecipe(
      productId: _productId!,
      basisQuantity: double.tryParse(_basisQuantity.text) ?? 1,
      basisUnit: _basisUnit.text.trim().isEmpty ? 'unit' : _basisUnit.text.trim(),
      items: items,
      costComponents: components,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _savedMessage = 'Recipe saved. Head to Cost Preview to see the price it calculates.';
        _items.clear();
        _components.clear();
      } else {
        _error = result.error;
      }
    });
  }

  Future<void> _showAddMaterialDialog(BuildContext context) {
    final name = TextEditingController();
    final unit = TextEditingController(text: 'kg');
    final cost = TextEditingController(text: '0');
    final stock = TextEditingController(text: '0');
    String category = 'raw_material';
    String sourceType = 'purchased';
    return showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: const Text('Add Raw Material'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const [DropdownMenuItem(value: 'raw_material', child: Text('Raw material')), DropdownMenuItem(value: 'packaging', child: Text('Packaging'))],
                  onChanged: (v) => setDialogState(() => category = v ?? category),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: sourceType,
                  decoration: const InputDecoration(labelText: 'Source'),
                  items: const [DropdownMenuItem(value: 'purchased', child: Text('Purchased')), DropdownMenuItem(value: 'farm_produced', child: Text('Farm produced'))],
                  onChanged: (v) => setDialogState(() => sourceType = v ?? sourceType),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: unit, decoration: const InputDecoration(labelText: 'Unit'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: cost, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit cost (\$)'))),
                ]),
                const SizedBox(height: 12),
                TextField(controller: stock, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Current stock')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                await context.read<MounehProvider>().createRawMaterial(
                      name: name.text.trim(),
                      category: category,
                      sourceType: sourceType,
                      unit: unit.text.trim().isEmpty ? 'unit' : unit.text.trim(),
                      defaultUnitCost: double.tryParse(cost.text) ?? 0,
                      currentStock: double.tryParse(stock.text) ?? 0,
                    );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('Add'),
            ),
          ],
        );
      }),
    );
  }
}
