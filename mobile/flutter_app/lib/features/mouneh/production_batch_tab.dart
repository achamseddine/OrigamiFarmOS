import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate;

/// Production Batch screen (tech spec v0.5 §6, screen 5): start a batch
/// from a recipe, record the raw materials actually used, and complete it
/// into finished goods. A completed batch is never edited again.
class ProductionBatchTab extends StatelessWidget {
  const ProductionBatchTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final batches = [...provider.batches]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final start = FilledButton.icon(onPressed: () => showStartMounehBatchDialog(context), icon: const Icon(Icons.add, size: 16), label: Text(context.t('mnStartBatch')));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeading(eyebrow: context.t('mnTabBatches'), title: context.t('mnBatchesTitle'), subtitle: context.t('mnBatchesSub'), actions: [start]),
          const SizedBox(height: FarmSpacing.md),
          if (batches.isEmpty)
            SectionCard(child: EmptyState(message: context.t('mnNoBatches'), icon: FarmIcon.barn, action: start))
          else
            for (final batch in batches) ...[
              _BatchCard(batch: batch, productName: provider.productById(batch.productId)?.name ?? batch.productId),
              const SizedBox(height: FarmSpacing.md),
            ],
          NoticeBanner(tone: NoticeTone.info, text: context.t('mnBatchNote')),
        ],
      ),
    );
  }
}

/// Start a batch of a product that has a recipe: how many, and where it
/// will be kept.
Future<void> showStartMounehBatchDialog(BuildContext context) {
  final provider = context.read<MounehProvider>();
  final eligible = provider.products.where((p) => provider.recipeFor(p.id) != null).toList();
  String? productId = eligible.isEmpty ? null : eligible.first.id;
  final qty = TextEditingController(text: productId == null ? '' : provider.productById(productId)!.defaultBatchSize.toStringAsFixed(0));
  final location = TextEditingController();
  String? error;
  bool saving = false;

  return showDialog(
    context: context,
    builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
      return AlertDialog(
        title: Text(context.t('mnStartBatch')),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (eligible.isEmpty)
                EmptyState(message: context.t('mnNeedRecipeFirst'), icon: FarmIcon.package, compact: true)
              else ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: productId,
                  decoration: InputDecoration(labelText: context.t('mnColProduct')),
                  items: [for (final p in eligible) DropdownMenuItem(value: p.id, child: Text(p.name))],
                  onChanged: (v) => setDialogState(() {
                    productId = v;
                    qty.text = provider.productById(v!)?.defaultBatchSize.toStringAsFixed(0) ?? '';
                  }),
                ),
                const SizedBox(height: 12),
                TextField(controller: qty, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnPlannedQty'))),
                const SizedBox(height: 12),
                TextField(controller: location, decoration: InputDecoration(labelText: context.t('mnLocationOptional'))),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.t('cancel'))),
          if (eligible.isNotEmpty)
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final planned = double.tryParse(qty.text.trim().replaceAll(',', '.'));
                      if (planned == null || planned <= 0) {
                        setDialogState(() => error = context.t('mnQtyInvalid'));
                        return;
                      }
                      setDialogState(() => saving = true);
                      final result = await provider.createBatch(
                        productId: productId!,
                        plannedQty: planned,
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
              child: Text(context.t('mnStartBatch')),
            ),
        ],
      );
    }),
  );
}

String mounehStatusLabel(BuildContext context, String status) {
  final key = 'mnSt_$status';
  final label = context.t(key);
  return label == key ? status.replaceAll('_', ' ') : label;
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
                    Eyebrow(batch.batchCode),
                    Text(productName, style: FarmTypography.textTheme.titleMedium),
                    Text('${context.t('mnStarted')} ${feedDate(batch.startedAt)}', style: FarmTypography.textTheme.bodySmall),
                  ],
                ),
              ),
              StatusPill(label: mounehStatusLabel(context, batch.status), level: level),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _stat(context.t('mnPlanned'), batch.plannedQty.toStringAsFixed(0)),
              if (batch.actualOutputQty != null) _stat(context.t('mnActualOutput'), batch.actualOutputQty!.toStringAsFixed(0)),
              if (batch.plannedUnitCost != null) _stat(context.t('mnPlannedUnitCost'), '\$${batch.plannedUnitCost!.toStringAsFixed(2)}'),
              if (batch.actualUnitCost != null) _stat(context.t('mnActualUnitCost'), '\$${batch.actualUnitCost!.toStringAsFixed(2)}'),
              if (batch.warehouseLocation != null) _stat(context.t('mnColLocation'), batch.warehouseLocation!),
            ],
          ),
          if (batch.isInProgress) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: [
              OutlinedButton(onPressed: () => _showConsumeDialog(context), child: Text(context.t('mnRecordUsage'))),
              FilledButton(onPressed: () => _showCompleteDialog(context), child: Text(context.t('mnCompleteBatch'))),
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

  Future<void> _showConsumeDialog(BuildContext context) {
    final provider = context.read<MounehProvider>();
    final controllers = {for (final c in batch.consumptions) c.materialId: TextEditingController(text: (c.actualQty ?? c.plannedQty).toStringAsFixed(2))};
    String? error;
    bool saving = false;
    return showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: Text(context.t('mnRecordUsage')),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.t('mnUsageNote'), style: FarmTypography.textTheme.bodySmall),
                  const SizedBox(height: 10),
                  for (final c in batch.consumptions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(children: [
                        Expanded(child: Text(provider.materialById(c.materialId)?.name ?? c.materialId, style: FarmTypography.textTheme.bodyMedium)),
                        SizedBox(
                          width: 130,
                          child: TextField(
                            controller: controllers[c.materialId],
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: '${context.t('mnPlanned')} ${c.plannedQty.toStringAsFixed(2)}'),
                          ),
                        ),
                      ]),
                    ),
                  if (error != null) Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.t('cancel'))),
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
              child: Text(context.t('save')),
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
          title: Text('${context.t('mnCompleteBatch')} — ${batch.batchCode}'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: actualOutput, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnActualOutput'))),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: waste, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnWaste')))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: damaged, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnDamaged')))),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: qualityStatus,
                  decoration: InputDecoration(labelText: context.t('mnQuality')),
                  items: [for (final s in kMounehQualityStatuses) DropdownMenuItem(value: s, child: Text(context.t('mnQ_$s')))],
                  onChanged: (v) => setDialogState(() => qualityStatus = v ?? qualityStatus),
                ),
                const SizedBox(height: 12),
                TextField(controller: laborHours, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnLaborHours'))),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.t('cancel'))),
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
              child: Text(context.t('mnCompleteBatch')),
            ),
          ],
        );
      }),
    );
  }
}

const kMounehQualityStatuses = ['good', 'substandard', 'rejected'];
