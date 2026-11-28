import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/local/local_store.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/animals_provider.dart';
import '../../providers/production_provider.dart';
import '../../sync/sync_controller.dart';
import 'milk_sessions.dart';

/// Milk recorded on this tablet while it was offline, until the farm
/// server has checked it (audit I-11, ADR-008).
///
/// The tablet may not know of a treatment recorded on another device, so
/// its milk is nobody's stored, sellable or handed-over milk until the
/// server has judged the milking against the treatments it knows of. The
/// card says so, and keeps what the server refused in view — the cow, the
/// litres, the day and the server's reason — with Try again and Discard,
/// instead of letting it vanish into the sync panel.
class MilkAwaitingCheckCard extends StatefulWidget {
  const MilkAwaitingCheckCard({super.key});

  @override
  State<MilkAwaitingCheckCard> createState() => _MilkAwaitingCheckCardState();
}

class _MilkAwaitingCheckCardState extends State<MilkAwaitingCheckCard> {
  Future<List<OutboxItem>>? _queue;
  (int, int)? _counts;

  void _reloadIfChanged() {
    final sync = context.watch<SyncController>();
    final counts = (sync.pendingCount, sync.failedCount);
    if (_queue == null || counts != _counts) {
      _counts = counts;
      _queue = sync.queuedItems();
    }
  }

  Future<void> _discard(OutboxItem item, String what) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t('macDiscardTitle')),
        content: Text(context.t('macDiscardBody').replaceAll('{milk}', what)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('cancel'))),
          FilledButton(key: const ValueKey('mac-discard-confirm'), onPressed: () => Navigator.of(context).pop(true), child: Text(context.t('macDiscard'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final production = context.read<ProductionProvider>();
    await context.read<SyncController>().discard(item.id);
    if (item.localId != null) await production.forgetLocalMilk(item.localId!);
  }

  @override
  Widget build(BuildContext context) {
    _reloadIfChanged();
    final production = context.watch<ProductionProvider>();
    final animals = context.watch<AnimalsProvider>();
    String name(String? id) => id == null ? '—' : (animals.find(id)?.name ?? id);
    return FutureBuilder<List<OutboxItem>>(
      future: _queue,
      builder: (context, snap) {
        final queue = snap.data ?? const <OutboxItem>[];
        final refused = [for (final i in queue) if (i.path == '/production/milk' && i.status == OutboxStatus.failed) i];
        // Waiting: still in the outbox to be sent. Once sent, the server's
        // own record replaces it at the next refresh; once refused, it is
        // listed below as refused.
        final queuedIds = {for (final i in queue) if (i.status == OutboxStatus.pending && i.localId != null) i.localId!};
        final waiting = [for (final r in production.milkRecords) if (r.awaitingCheck && queuedIds.contains(r.id)) r];
        if (waiting.isEmpty && refused.isEmpty) return const SizedBox.shrink();
        final waitingL = waiting.fold<double>(0, (s, r) => s + r.liters);
        return Padding(
          padding: const EdgeInsets.only(bottom: FarmSpacing.md),
          child: SectionCard(
            key: const ValueKey('milk-awaiting-check-card'),
            title: context.t('macTitle'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (waiting.isNotEmpty) ...[
                Text(context.t('macIntro').replaceAll('{liters}', _litres(waitingL)), style: FarmTypography.textTheme.bodySmall),
                const SizedBox(height: 8),
                for (final r in waiting) _WaitingRow(record: r, animal: name(r.animalId)),
              ],
              if (refused.isNotEmpty) ...[
                if (waiting.isNotEmpty) const Divider(height: 20, color: FarmColors.border),
                Text(context.t('macRefusedIntro'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.danger)),
                const SizedBox(height: 8),
                for (final item in refused) _refusedRow(context, item, name),
              ],
            ]),
          ),
        );
      },
    );
  }

  Widget _refusedRow(BuildContext context, OutboxItem item, String Function(String?) name) {
    final body = item.body is Map ? (item.body as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final at = DateTime.tryParse('${body['recorded_at']}')?.toLocal() ?? item.createdAt;
    final liters = (body['liters'] as num?)?.toDouble() ?? 0;
    final what = '${name(body['animal_id'] as String?)} · ${dayLabel(at)} · ${milkSessionLabel(context, '${body['session'] ?? 'morning'}')} · ${_litres(liters)} L';
    return Container(
      key: ValueKey('mac-refused-${item.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(color: FarmColors.tint(FarmColors.danger, 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(what, style: FarmTypography.textTheme.titleSmall)),
          StatusPill(label: context.t('macRefused'), level: FarmStatusLevel.alert, dense: true),
        ]),
        if ((item.lastError ?? '').isNotEmpty) Text(item.lastError!, style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
        Wrap(spacing: 8, children: [
          TextButton(key: ValueKey('mac-discard-${item.id}'), onPressed: () => _discard(item, what), child: Text(context.t('macDiscard'))),
          FilledButton.tonal(
            key: ValueKey('mac-retry-${item.id}'),
            onPressed: () => context.read<SyncController>().retry(item.id),
            child: Text(context.t('macTryAgain')),
          ),
        ]),
      ]),
    );
  }
}

class _WaitingRow extends StatelessWidget {
  const _WaitingRow({required this.record, required this.animal});
  final MilkRecord record;
  final String animal;

  @override
  Widget build(BuildContext context) {
    final r = record;
    return Padding(
      key: ValueKey('mac-waiting-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Text('$animal · ${dayLabel(r.recordedAt.toLocal())} · ${milkSessionLabel(context, r.session)} · ${_litres(r.liters)} L · ${context.t(r.destination)}',
              style: FarmTypography.textTheme.titleSmall),
        ),
        StatusPill(label: context.t('macWaiting'), level: FarmStatusLevel.watch, dense: true),
      ]),
    );
  }
}

String _litres(double l) => l.toStringAsFixed(l == l.roundToDouble() ? 0 : 1);
