import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';

/// Production Batch screen (tech spec v0.5 §6, screen 5): create batches
/// from a recipe, record actual raw-material use, and complete a batch
/// into finished goods. A completed batch is never edited again.
class ProductionBatchTab extends StatelessWidget {
  const ProductionBatchTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final batches = [...provider.batches]..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Production Batches', style: FarmTypography.textTheme.titleLarge)),
              FilledButton.icon(onPressed: () => _showStartBatchDialog(context), icon: const Icon(Icons.add, size: 16), label: const Text('Start New Batch')),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          if (batches.isEmpty)
            SectionCard(child: Text('No batches yet.', style: FarmTypography.textTheme.bodySmall))
          else
            for (final batch in batches) ...[
              _BatchCard(batch: batch, productName: provider.productById(batch.productId)?.name ?? batch.productId),
              const SizedBox(height: FarmSpacing.md),
            ],
        ],
      ),
    );
  }

  Future<void> _showStartBatchDialog(BuildContext context) {
    final provider = context.read<MounehProvider>();
    String? productId = provider.products.where((p) => provider.recipeFor(p.id) != null).map((p) => p.id).firstOrNull;
    final qty = TextEditingController();
    final location = TextEditingController();
    String? error;
    bool saving = false;

    return showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
        final eligibleProducts = provider.products.where((p) => provider.recipeFor(p.id) != null).toList();
        qty.text = productId != null ? provider.productById(productId!)!.defaultBatchSize.toString() : '';
        return AlertDialog(
          title: const Text('Start New Batch'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eligibleProducts.isEmpty)
                  Text('No product has a recipe yet. Add one on the Recipes & Materials tab first.', style: FarmTypography.textTheme.bodySmall)
                else ...[
                  DropdownButtonFormField<String>(
                    value: productId,
                    decoration: const InputDecoration(labelText: 'Product'),
                    items: [for (final p in eligibleProducts) DropdownMenuItem(value: p.id, child: Text(p.name))],
                    onChanged: (v) => setDialogState(() {
                      productId = v;
                      qty.text = provider.productById(v!)?.defaultBatchSize.toString() ?? '';
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Planned quantity')),
                  const SizedBox(height: 12),
                  TextField(controller: location, decoration: const InputDecoration(labelText: 'Warehouse location (optional)')),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            if (eligibleProducts.isNotEmpty)
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        setDialogState(() => saving = true);
                        final result = await provider.createBatch(
                          productId: productId!,
                          plannedQty: double.tryParse(qty.text) ?? 0,
                          warehouseLocation: location.text.trim().isEmpty ? null : location.text.trim(),
                        );
                        if (result.success) {
                          if (dialogContext.mounted) Navigator.pop(dialogContext);
                        } else {
                          setDialogState(() {
                            saving = false;
                            error = result.error;
                          });
                        }
                      },
                child: const Text('Start Batch'),
              ),
          ],
        );
      }),
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.batch, required this.productName});
  final ProductionBatch batch;
  final String productName;

  @override
  Widget build(BuildContext context) {
    final level = switch (batch.status) {
      'completed' => FarmStatusLevel.good,
      'cancelled' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.watch,
    };
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$productName — ${batch.batchCode}', style: FarmTypography.textTheme.titleMedium),
                    Text('Started ${_dateLabel(batch.startedAt)}', style: FarmTypography.textTheme.bodySmall),
                  ],
                ),
              ),
              StatusPill(label: batch.status.replaceAll('_', ' '), level: level),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _stat('Planned', '${batch.plannedQty.toStringAsFixed(0)} units'),
              if (batch.actualOutputQty != null) _stat('Actual output', '${batch.actualOutputQty!.toStringAsFixed(0)} units'),
              if (batch.plannedUnitCost != null) _stat('Planned cost/unit', '\$${batch.plannedUnitCost!.toStringAsFixed(2)}'),
              if (batch.actualUnitCost != null) _stat('Actual cost/unit', '\$${batch.actualUnitCost!.toStringAsFixed(2)}'),
              if (batch.warehouseLocation != null) _stat('Location', batch.warehouseLocation!),
            ],
          ),
          if (batch.isInProgress) ...[
            const SizedBox(height: 12),
            Row(children: [
              OutlinedButton(onPressed: () => _showConsumeDialog(context), child: const Text('Record Actual Usage')),
              const SizedBox(width: 10),
              FilledButton(onPressed: () => _showCompleteDialog(context), child: const Text('Complete Batch')),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: FarmTypography.textTheme.bodySmall),
          Text(value, style: FarmTypography.textTheme.titleSmall),
        ],
      );

  String _dateLabel(DateTime dt) => '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  Future<void> _showConsumeDialog(BuildContext context) {
    final provider = context.read<MounehProvider>();
    final controllers = {for (final c in batch.consumptions) c.materialId: TextEditingController(text: (c.actualQty ?? c.plannedQty).toStringAsFixed(2))};
    String? error;
    bool saving = false;
    return showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: const Text('Record Actual Raw Material Usage'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in batch.consumptions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(children: [
                        Expanded(child: Text(provider.materialById(c.materialId)?.name ?? c.materialId, style: FarmTypography.textTheme.bodyMedium)),
                        SizedBox(
                          width: 110,
                          child: TextField(controller: controllers[c.materialId], keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Planned ${c.plannedQty.toStringAsFixed(2)}')),
                        ),
                      ]),
                    ),
                  if (error != null) Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setDialogState(() => saving = true);
                      final result = await provider.consumeBatchInputs(
                        batchId: batch.id,
                        actualQtyByMaterial: {for (final e in controllers.entries) e.key: double.tryParse(e.value.text) ?? 0},
                      );
                      if (result.success) {
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } else {
                        setDialogState(() {
                          saving = false;
                          error = result.error;
                        });
                      }
                    },
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _showCompleteDialog(BuildContext context) {
    final provider = context.read<MounehProvider>();
    final actualOutput = TextEditingController(text: batch.plannedQty.toStringAsFixed(0));
    final waste = TextEditingController(text: '0');
    final damaged = TextEditingController(text: '0');
    final laborHours = TextEditingController();
    String qualityStatus = 'good';
    String? error;
    bool saving = false;
    return showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: const Text('Complete Batch'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: actualOutput, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Actual output quantity')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: waste, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Waste qty'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: damaged, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Damaged qty'))),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: qualityStatus,
                  decoration: const InputDecoration(labelText: 'Quality status'),
                  items: kMounehQualityStatuses.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (v) => setDialogState(() => qualityStatus = v ?? qualityStatus),
                ),
                const SizedBox(height: 12),
                TextField(controller: laborHours, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Labor hours (optional)')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setDialogState(() => saving = true);
                      final shelfLifeDays = provider.productById(batch.productId)?.shelfLifeDays;
                      final result = await provider.completeBatch(
                        batchId: batch.id,
                        actualOutputQty: double.tryParse(actualOutput.text) ?? batch.plannedQty,
                        wasteQty: double.tryParse(waste.text) ?? 0,
                        damagedQty: double.tryParse(damaged.text) ?? 0,
                        qualityStatus: qualityStatus,
                        laborHours: double.tryParse(laborHours.text),
                        expiryDate: shelfLifeDays == null ? null : DateTime.now().add(Duration(days: shelfLifeDays)),
                      );
                      if (result.success) {
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } else {
                        setDialogState(() {
                          saving = false;
                          error = result.error;
                        });
                      }
                    },
              child: const Text('Complete'),
            ),
          ],
        );
      }),
    );
  }
}

const kMounehQualityStatuses = ['good', 'substandard', 'rejected'];

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
