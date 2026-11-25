import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/approvals.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/approvals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/production_provider.dart';
import '../health/pharmacy_tab.dart' show askReason;
import 'ask_to_buy_dialog.dart' show purchaseStatusLevel;

/// What waits for the farm manager, and what this person asked for.
///
/// The manager sees each mix, correction and request to buy an employee
/// sent, with Approve and Reject (a rejection says why). An employee sees
/// their own requests and how each was decided, and can withdraw one still
/// waiting. Shown on My Day for everyone, and on the Feed and Milk pages
/// for their own requests; it takes no room when there is nothing.
class ApprovalsCard extends StatelessWidget {
  const ApprovalsCard({super.key, this.modules});

  /// Only requests decided in these modules (null: all). Requests to buy
  /// belong to Feed & Nutrition and Inventory.
  final Set<String>? modules;

  bool _in(String module) => modules == null || modules!.contains(module);
  bool get _purchases => modules == null || modules!.contains(FarmModule.feedNutrition) || modules!.contains(FarmModule.inventory);

  @override
  Widget build(BuildContext context) {
    final approvals = context.watch<ApprovalsProvider>();
    final access = context.watch<AccessProvider>();
    final waiting = [for (final r in approvals.waiting) if (_in(r.moduleCode) && access.can(r.moduleCode, PermissionAction.approve)) r];
    final buying = _purchases && (access.canBuyFeed || access.can(FarmModule.inventory, PermissionAction.approve))
        ? approvals.purchasesWaiting
        : const <PurchaseRequest>[];
    // An employee's own requests: those still waiting, and the answers of
    // the last three days.
    final recent = DateTime.now().subtract(const Duration(days: 3));
    final mine = [for (final r in approvals.mine) if (_in(r.moduleCode) && (r.pending || (r.decidedAt?.isAfter(recent) ?? false))) r];
    final myBuying = _purchases
        ? [for (final p in approvals.myPurchases) if (p.waiting || p.deliverable || p.requestedAt.isAfter(recent)) p]
        : const <PurchaseRequest>[];
    if (waiting.isEmpty && buying.isEmpty && mine.isEmpty && myBuying.isEmpty) return const SizedBox.shrink();

    final toDecide = waiting.length + buying.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: FarmSpacing.md),
      child: SectionCard(
        key: const ValueKey('approvals-card'),
        title: toDecide > 0 ? '${context.t('apWaitingForYou')} · $toDecide' : context.t('apYourRequests'),
        subtitle: toDecide > 0 ? context.t('apWaitingForYouSub') : context.t('apYourRequestsSub'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final r in waiting) _DecideRow(request: r),
          for (final p in buying) _DecidePurchaseRow(request: p),
          if (toDecide > 0 && (mine.isNotEmpty || myBuying.isNotEmpty)) ...[
            const SizedBox(height: FarmSpacing.sm),
            Text(context.t('apYourRequests'), style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 4),
          ],
          for (final r in mine) _MineRow(request: r),
          for (final p in myBuying) _MinePurchaseRow(request: p),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.detail, this.trailing, this.actions = const []});
  final String title;
  final String? detail;
  final Widget? trailing;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(title, style: FarmTypography.textTheme.titleSmall)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
        if (detail != null && detail!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(detail!, style: FarmTypography.textTheme.bodySmall),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 6, children: actions),
        ],
      ]),
    );
  }
}

String _who(BuildContext context, String? name, DateTime at) {
  final l = at.toLocal();
  return '${context.t('apAskedBy')} ${name ?? '—'} · ${l.day}/${l.month} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

void _told(BuildContext context, WriteResultLike result, String okKey) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.ok ? context.t(okKey) : (result.error ?? context.t('couldNotSave')))));
}

/// The two fields of a write result the card reports.
typedef WriteResultLike = ({bool ok, String? error});

class _DecideRow extends StatefulWidget {
  const _DecideRow({required this.request});
  final ApprovalRequest request;

  @override
  State<_DecideRow> createState() => _DecideRowState();
}

class _DecideRowState extends State<_DecideRow> {
  bool _busy = false;

  Future<void> _approve() async {
    final approvals = context.read<ApprovalsProvider>();
    setState(() => _busy = true);
    var result = await approvals.approve(widget.request);
    // A mix asked for when the stock on record was short: the manager may
    // record it anyway (their stock override), or leave it waiting.
    if (!result.success && mounted && context.read<AccessProvider>().canOverrideFeedStock && (result.error ?? '').toLowerCase().contains('stock')) {
      // v0.8.4: approving past the stock says why; the reason stays on the
      // stock exception with the employee who asked and the manager.
      final why = await showDialog<String>(context: context, builder: (_) => _ApproveAnywayDialog(message: result.error ?? ''));
      if (why != null && why.isNotEmpty) result = await approvals.approve(widget.request, allowNegative: true, overrideReason: why);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.success && !result.queued) _refreshAfter(context, widget.request);
    _told(context, (ok: result.success, error: result.error), result.queued ? 'apSentOffline' : 'apApproved');
  }

  /// What the approval changed, shown as the server now has it.
  static void _refreshAfter(BuildContext context, ApprovalRequest r) {
    switch (r.kind) {
      case 'feed_mix':
        context.read<FeedingProvider>().afterMixApproved();
      case 'milk_correction':
        context.read<ProductionProvider>().load();
        context.read<AnimalsProvider>().load();
      case 'feeding_correction':
        context.read<FeedingProvider>().afterFeedingCorrected(r.subjectId);
    }
  }

  Future<void> _reject() async {
    final why = await askReason(context, title: context.t('apReject'), label: context.t('apRejectWhy'));
    if (why == null || !mounted) return;
    setState(() => _busy = true);
    final result = await context.read<ApprovalsProvider>().reject(widget.request, why);
    if (!mounted) return;
    setState(() => _busy = false);
    _told(context, (ok: result.success, error: result.error), 'apRejected');
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return _Row(
      title: r.summary.isEmpty ? context.t('apKind_${r.kind}') : r.summary,
      detail: [_who(context, r.requestedByName, r.requestedAt), if (r.reason != null && r.reason!.isNotEmpty) '${context.t('reason')}: ${r.reason}'].join('\n'),
      trailing: StatusPill(label: context.t('apKind_${r.kind}'), level: FarmStatusLevel.info, dense: true),
      actions: [
        OutlinedButton(key: ValueKey('reject-${r.id}'), onPressed: _busy ? null : _reject, child: Text(context.t('apReject'))),
        FilledButton(key: ValueKey('approve-${r.id}'), onPressed: _busy ? null : _approve, child: Text(context.t('apApprove'))),
      ],
    );
  }
}

/// "Approve anyway" for a mix short of stock: the server's arithmetic, and
/// the reason the manager records it anyway (required).
class _ApproveAnywayDialog extends StatefulWidget {
  const _ApproveAnywayDialog({required this.message});
  final String message;

  @override
  State<_ApproveAnywayDialog> createState() => _ApproveAnywayDialogState();
}

class _ApproveAnywayDialogState extends State<_ApproveAnywayDialog> {
  final _why = TextEditingController();

  @override
  void dispose() {
    _why.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(context.t('feedStockShortTitle')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.message.replaceAll(RegExp(r'\s*Pass allow_negative=true.*$'), '')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('approve-anyway-reason'),
            controller: _why,
            autofocus: true,
            maxLength: 300,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.t('feedOverrideReason')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
          FilledButton(
            key: const ValueKey('approve-anyway'),
            onPressed: _why.text.trim().isEmpty ? null : () => Navigator.pop(context, _why.text.trim()),
            child: Text(context.t('apApproveAnyway')),
          ),
        ],
      );
}

class _DecidePurchaseRow extends StatefulWidget {
  const _DecidePurchaseRow({required this.request});
  final PurchaseRequest request;

  @override
  State<_DecidePurchaseRow> createState() => _DecidePurchaseRowState();
}

class _DecidePurchaseRowState extends State<_DecidePurchaseRow> {
  bool _busy = false;

  Future<void> _approve() async {
    setState(() => _busy = true);
    final result = await context.read<ApprovalsProvider>().approvePurchase(widget.request);
    if (!mounted) return;
    setState(() => _busy = false);
    _told(context, (ok: result.success, error: result.error), result.queued ? 'apSentOffline' : 'apApproved');
  }

  Future<void> _reject() async {
    final why = await askReason(context, title: context.t('apReject'), label: context.t('apRejectWhy'));
    if (why == null || !mounted) return;
    setState(() => _busy = true);
    final result = await context.read<ApprovalsProvider>().rejectPurchase(widget.request, why);
    if (!mounted) return;
    setState(() => _busy = false);
    _told(context, (ok: result.success, error: result.error), 'apRejected');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.request;
    return _Row(
      title: '${context.t('prPurchase')} ${p.number}: ${p.what}',
      detail: [_who(context, p.requestedByName, p.requestedAt), if (p.justification != null && p.justification!.isNotEmpty) p.justification!].join('\n'),
      trailing: StatusPill(label: context.t('prPurchase'), level: FarmStatusLevel.info, dense: true),
      actions: [
        OutlinedButton(key: ValueKey('reject-${p.id}'), onPressed: _busy ? null : _reject, child: Text(context.t('apReject'))),
        FilledButton(key: ValueKey('approve-${p.id}'), onPressed: _busy ? null : _approve, child: Text(context.t('apApprove'))),
      ],
    );
  }
}

class _MineRow extends StatelessWidget {
  const _MineRow({required this.request});
  final ApprovalRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final level = switch (r.status) { 'approved' => FarmStatusLevel.good, 'rejected' => FarmStatusLevel.alert, 'pending' => FarmStatusLevel.watch, _ => FarmStatusLevel.neutral };
    return _Row(
      title: r.summary.isEmpty ? context.t('apKind_${r.kind}') : r.summary,
      detail: [
        if (r.decidedByName != null && !r.pending) '${context.t('apDecidedBy')} ${r.decidedByName}',
        if (r.decisionNote != null && r.decisionNote!.isNotEmpty) r.decisionNote!,
      ].join(' · '),
      trailing: StatusPill(label: context.t('apStatus_${r.status}'), level: level, dense: true),
      actions: [
        if (r.pending)
          TextButton(
            key: ValueKey('withdraw-${r.id}'),
            onPressed: () async {
              final result = await context.read<ApprovalsProvider>().withdraw(r);
              if (context.mounted) _told(context, (ok: result.success, error: result.error), 'apWithdrawn');
            },
            child: Text(context.t('apWithdraw')),
          ),
      ],
    );
  }
}

class _MinePurchaseRow extends StatelessWidget {
  const _MinePurchaseRow({required this.request});
  final PurchaseRequest request;

  @override
  Widget build(BuildContext context) {
    final p = request;
    return _Row(
      title: '${context.t('prPurchase')} ${p.number}: ${p.what}',
      detail: [if (p.deliverable) context.t('prApprovedRecordDelivery'), if (p.decisionNote != null && p.decisionNote!.isNotEmpty) p.decisionNote!].join(' · '),
      trailing: StatusPill(label: context.t('prStatus_${p.status}'), level: purchaseStatusLevel(p.status), dense: true),
    );
  }
}
