import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/milk_sales.dart';
import '../../providers/access_provider.dart';
import '../../providers/milk_sales_provider.dart';
import '../../providers/sales_provider.dart';
import '../health/pharmacy_tab.dart' show askReason;

/// Money as the farm writes it: "$12.50" for dollars, "12.50 LBP" otherwise.
String money(double amount, String currency) {
  final v = amount.abs() >= 1000 ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
  return currency == 'USD' ? '\$$v' : '$v $currency';
}

String litres(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _date(DateTime d) {
  final l = d.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}

/// After a sale changes revenue, Sales & Finance shows it.
void _refreshFinance(BuildContext context) {
  try {
    context.read<SalesProvider>().load();
  } catch (_) {
    // Someone without Finance has no Sales & Finance to refresh.
  }
}

// ------------------------------------------------------------- sell milk
/// Milk sold from the tank: the day, litres, price per litre (the last one
/// offered), the buyer, paid now or to be paid. The total is worked out as
/// it is typed. More than the tank holds: the manager may record it anyway
/// (the records are behind); anyone else is told to record the milk first.
Future<void> showSellMilkDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _SellMilkDialog());

class _SellMilkDialog extends StatefulWidget {
  const _SellMilkDialog();

  @override
  State<_SellMilkDialog> createState() => _SellMilkDialogState();
}

class _SellMilkDialogState extends State<_SellMilkDialog> {
  final _liters = TextEditingController();
  late final _price = TextEditingController(text: _initialPrice());
  late final _buyer = TextEditingController(text: context.read<MilkSalesProvider>().tank.lastBuyerName ?? '');
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  DateTime _day = DateTime.now();
  bool _paid = true;
  bool _anyway = false;
  bool _saving = false;
  String? _error;

  String _initialPrice() {
    final p = context.read<MilkSalesProvider>().tank.lastPricePerLiter;
    return p == null ? '' : (p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toString());
  }

  @override
  void initState() {
    super.initState();
    _liters.addListener(() => setState(() {}));
    _price.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_liters, _price, _buyer, _reference, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _litersValue => parseLocalizedDouble(_liters.text);
  double? get _priceValue => parseLocalizedDouble(_price.text);

  Future<void> _submit() async {
    final liters = _litersValue;
    final price = _priceValue;
    if (liters == null || liters <= 0) {
      setState(() => _error = context.t('msSayLiters'));
      return;
    }
    if (price == null || price < 0) {
      setState(() => _error = context.t('msSayPrice'));
      return;
    }
    final tank = context.read<MilkSalesProvider>().tank;
    final over = liters > tank.balanceL + 0.0005;
    final canOverride = context.read<AccessProvider>().canAdjustMilkTank;
    if (over && !(canOverride && _anyway)) {
      setState(() => _error = context.t(canOverride ? 'msOverTankConfirm' : 'msOverTank').replaceAll('{tank}', litres(tank.balanceL < 0 ? 0 : tank.balanceL)));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<MilkSalesProvider>().sell(
          liters: liters,
          pricePerLiter: price,
          soldAt: recordedInstant(_day),
          buyerName: _buyer.text,
          paid: _paid,
          reference: _reference.text,
          notes: _notes.text,
          allowNegative: over && _anyway,
        );
    if (!mounted) return;
    if (result.success) {
      if (!result.queued) _refreshFinance(context);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.queued ? context.t('msSavedOffline') : '${context.t('msSold')} ${litres(liters)} L — ${money(liters * price, tank.currency)}'),
      ));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MilkSalesProvider>();
    final tank = provider.tank;
    final liters = _litersValue;
    final price = _priceValue;
    final total = liters != null && price != null ? liters * price : null;
    final over = liters != null && liters > tank.balanceL + 0.0005;
    final canOverride = context.watch<AccessProvider>().canAdjustMilkTank;
    return FarmFormDialog(
      title: Text(context.t('msSellMilk')),
      width: 520,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          key: const ValueKey('sell-tank'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: FarmColors.tint(FarmColors.milkBlue, 0.10), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.water_drop_outlined, color: FarmColors.milkBlue),
            const SizedBox(width: 10),
            Expanded(child: Text('${context.t('msInTank')}: ${litres(tank.balanceL)} L', style: FarmTypography.textTheme.titleSmall)),
            if (tank.balanceL > 0)
              TextButton(onPressed: () => _liters.text = litres(tank.balanceL), child: Text(context.t('msSellAll'))),
          ]),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: RecordDateButton(label: context.t('msSoldOn'), value: _day, maxDaysBack: 60, onPicked: (d) => setState(() => _day = d)),
        ),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('sell-liters'),
              controller: _liters,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: context.t('msLiters'), suffixText: 'L'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const ValueKey('sell-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: context.t('msPricePerLiter'), suffixText: '${tank.currency}/L'),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
          total == null ? '${context.t('msTotal')}: —' : '${context.t('msTotal')}: ${money(total, tank.currency)}',
          key: const ValueKey('sell-total'),
          style: FarmTypography.textTheme.titleMedium,
        ),
        if (over) ...[
          const SizedBox(height: 10),
          NoticeBanner(
            title: context.t('msOverTankTitle'),
            text: context.t(canOverride ? 'msOverTankManager' : 'msOverTank').replaceAll('{tank}', litres(tank.balanceL < 0 ? 0 : tank.balanceL)),
          ),
          if (canOverride)
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _anyway,
                title: Text(context.t('msRecordAnyway')),
                onChanged: (v) => setState(() => _anyway = v ?? false),
              ),
            ),
        ],
        const SizedBox(height: 14),
        TextField(controller: _buyer, decoration: InputDecoration(labelText: context.t('msBuyer'), hintText: context.t('msBuyerHint'))),
        if (provider.recentBuyers.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final b in provider.recentBuyers) ActionChip(label: Text(b), onPressed: () => setState(() => _buyer.text = b)),
          ]),
        ],
        const SizedBox(height: 14),
        Text(context.t('msPayment'), style: FarmTypography.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          ChoiceChip(key: const ValueKey('sell-paid'), label: Text(context.t('msPaidNow')), selected: _paid, onSelected: (_) => setState(() => _paid = true)),
          ChoiceChip(key: const ValueKey('sell-pending'), label: Text(context.t('msToBePaid')), selected: !_paid, onSelected: (_) => setState(() => _paid = false)),
        ]),
        const SizedBox(height: 14),
        TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('msReference'), hintText: context.t('optional'))),
        const SizedBox(height: 10),
        TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('msSaveSale')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- the tank
/// The farm manager's: a count of the tank (the litres really there), or
/// milk that left it outside a sale — spoiled, fed to calves, home use.
Future<void> showMilkTankDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _MilkTankDialog());

class _MilkTankDialog extends StatefulWidget {
  const _MilkTankDialog();

  @override
  State<_MilkTankDialog> createState() => _MilkTankDialogState();
}

class _MilkTankDialogState extends State<_MilkTankDialog> {
  static const _reasons = ['count', 'spoiled', 'calves', 'home_use', 'other'];
  String _reason = 'count';
  final _liters = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _liters.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final v = parseLocalizedDouble(_liters.text);
    if (v == null || v < 0 || (_reason != 'count' && v == 0)) {
      setState(() => _error = context.t('msSayLiters'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<MilkSalesProvider>().adjust(
          reason: _reason,
          liters: _reason == 'count' ? null : v,
          countedLevel: _reason == 'count' ? v : null,
          notes: _notes.text,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'msSavedOffline' : 'saved'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tank = context.watch<MilkSalesProvider>().tank;
    return FarmFormDialog(
      title: Text(context.t('msTankTitle')),
      width: 480,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${context.t('msOnRecord')}: ${litres(tank.balanceL)} L', style: FarmTypography.textTheme.titleSmall),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final r in _reasons)
            ChoiceChip(key: ValueKey('tank-$r'), label: Text(context.t('msTank_$r')), selected: _reason == r, onSelected: (_) => setState(() => _reason = r)),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('tank-liters'),
          controller: _liters,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t(_reason == 'count' ? 'msCountedLiters' : 'msLitersOut'), suffixText: 'L'),
        ),
        const SizedBox(height: 6),
        Text(context.t(_reason == 'count' ? 'msCountHint' : 'msOutHint'), style: FarmTypography.textTheme.bodySmall),
        const SizedBox(height: 12),
        TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- the card
/// The Milk page's tank and sales: what is in the tank, Sell milk, the
/// sales of the last weeks — paid or to be paid — with Mark paid, and
/// Cancel for the manager; Count the tank for the manager.
class MilkTankCard extends StatelessWidget {
  const MilkTankCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MilkSalesProvider>();
    final access = context.watch<AccessProvider>();
    final tank = provider.tank;
    final recent = provider.sales.take(10).toList();
    return SectionCard(
      key: const ValueKey('milk-tank-card'),
      title: context.t('msTankAndSales'),
      subtitle: context.t('msTankAndSalesSub'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LayoutBuilder(builder: (context, c) {
          final figures = Wrap(spacing: FarmSpacing.lg, runSpacing: 8, children: [
            _Figure(label: context.t('msInTank'), value: '${litres(tank.balanceL)} L', strong: true),
            _Figure(label: context.t('msUnpaid'), value: money(provider.unpaidAmount, tank.currency)),
            if (tank.lastPricePerLiter != null) _Figure(label: context.t('msLastPrice'), value: '${money(tank.lastPricePerLiter!, tank.currency)}/L'),
          ]);
          final buttons = Wrap(spacing: 8, runSpacing: 8, children: [
            if (access.canSellMilk)
              FilledButton.icon(
                key: const ValueKey('sell-milk'),
                onPressed: () => showSellMilkDialog(context),
                icon: const Icon(Icons.sell_outlined, size: 18),
                label: Text(context.t('msSellMilk')),
              ),
            if (access.canAdjustMilkTank)
              OutlinedButton.icon(
                key: const ValueKey('count-tank'),
                onPressed: () => showMilkTankDialog(context),
                icon: const Icon(Icons.straighten, size: 18),
                label: Text(context.t('msCountTank')),
              ),
          ]);
          if (c.maxWidth < 620) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [figures, const SizedBox(height: 12), buttons]);
          return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(child: figures), buttons]);
        }),
        const SizedBox(height: 14),
        if (recent.isEmpty)
          Text(context.t('msNoSales'), style: FarmTypography.textTheme.bodySmall)
        else
          for (final s in recent) _SaleRow(sale: s),
      ]),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.strong = false});
  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: FarmTypography.textTheme.bodySmall),
        Text(value, style: strong ? FarmTypography.textTheme.headlineMedium : FarmTypography.textTheme.titleMedium),
      ]);
}

class _SaleRow extends StatelessWidget {
  const _SaleRow({required this.sale});
  final MilkSale sale;

  @override
  Widget build(BuildContext context) {
    final s = sale;
    final access = context.watch<AccessProvider>();
    final pill = s.cancelled
        ? StatusPill(label: context.t('msCancelled'), level: FarmStatusLevel.neutral, dense: true)
        : StatusPill(label: context.t(s.paid ? 'msPaid' : 'msToBePaid'), level: s.paid ? FarmStatusLevel.good : FarmStatusLevel.watch, dense: true);
    return Container(
      key: ValueKey('milk-sale-${s.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(
              '${_date(s.soldAt)} · ${litres(s.liters)} L × ${money(s.pricePerLiter, s.currency)} = ${money(s.amount, s.currency)}',
              style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: s.cancelled ? TextDecoration.lineThrough : null),
            ),
          ),
          const SizedBox(width: 8),
          pill,
        ]),
        if ((s.buyerName ?? '').isNotEmpty || s.cancelReason != null || s.pending)
          Text(
            [
              if ((s.buyerName ?? '').isNotEmpty) s.buyerName!,
              if (s.cancelReason != null) '${context.t('reason')}: ${s.cancelReason}',
              if (s.pending) context.t('msWaitingSync'),
            ].join(' · '),
            style: FarmTypography.textTheme.bodySmall,
          ),
        if (!s.cancelled && !s.pending && ((!s.paid && access.canSellMilk) || access.canCancelMilkSale))
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            if (!s.paid && access.canSellMilk)
              TextButton(
                key: ValueKey('mark-paid-${s.id}'),
                onPressed: () async {
                  final result = await context.read<MilkSalesProvider>().markPaid(s);
                  if (!context.mounted) return;
                  if (result.success && !result.queued) _refreshFinance(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('msMarkedPaid') : (result.error ?? context.t('couldNotSave')))));
                },
                child: Text(context.t('msMarkPaid')),
              ),
            if (access.canCancelMilkSale)
              TextButton(
                key: ValueKey('cancel-sale-${s.id}'),
                onPressed: () async {
                  final why = await askReason(context, title: context.t('msCancelSale'), label: context.t('msCancelWhy'));
                  if (why == null || !context.mounted) return;
                  final result = await context.read<MilkSalesProvider>().cancel(s, why);
                  if (!context.mounted) return;
                  if (result.success && !result.queued) _refreshFinance(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('msSaleCancelled') : (result.error ?? context.t('couldNotSave')))));
                },
                child: Text(context.t('msCancelSale')),
              ),
          ]),
      ]),
    );
  }
}
