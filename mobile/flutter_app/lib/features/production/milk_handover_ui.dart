import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/farm_clock.dart';
import '../../core/util/number_input.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/milk_sales.dart';
import '../../providers/access_provider.dart';
import '../../providers/milk_sales_provider.dart';
import '../finance/finance_forms.dart' show grouped, refreshMoney, showReceivePaymentDialog;
import 'milk_sales_ui.dart' show litres, money;
import 'milk_sessions.dart';

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _dayLabel(BuildContext context, String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  final today = DateTime.now();
  final t = DateTime(today.year, today.month, today.day);
  final diff = t.difference(DateTime(d.year, d.month, d.day)).inDays;
  if (diff == 0) return context.t('today');
  if (diff == 1) return context.t('yesterday');
  return '${d.day}/${d.month}/${d.year}';
}

/// "$0.50/L" or "44,750 LBP/L" — the collector's agreed price.
String collectorPrice(MilkRoutine r) {
  final p = r.collectorPrice;
  if (p == null) return '—';
  return r.collectorCurrency == 'USD' ? '${money(p, 'USD')}/L' : '${grouped(p)} ${r.collectorCurrency}/L';
}

String _collectorAmount(MilkRoutine r, double liters) {
  final p = r.collectorPrice ?? 0;
  return r.collectorCurrency == 'USD' ? money(liters * p, 'USD') : '${grouped(liters * p)} ${r.collectorCurrency}';
}

// ------------------------------------------------------------- the card
/// The Milk page's routine: each milking of today and yesterday — milk
/// into the tank, to the calves, to the collector — with *Hand over* for a
/// milking not yet handed over, and *Collector paid* for the week.
class MilkHandoverCard extends StatelessWidget {
  const MilkHandoverCard({super.key});

  @override
  Widget build(BuildContext context) {
    final milk = context.watch<MilkSalesProvider>();
    final access = context.watch<AccessProvider>();
    final routine = milk.routine;
    final today = _iso(DateTime.now());
    final yesterday = _iso(DateTime.now().subtract(const Duration(days: 1)));
    final shown = [
      for (final m in milk.handovers)
        // A milking shows once it has milk recorded (or was handed over):
        // the afternoon one appears after the afternoon milking, not before.
        if ((m.day == today || m.day == yesterday) && (m.milkedL > 0 || m.handedOver)) m,
    ]..sort((a, b) => '${b.day}${_order(b.session)}'.compareTo('${a.day}${_order(a.session)}'));
    final owed = milk.collectorUnpaid;
    final owedAmount = owed.fold(0.0, (t, s) => t + s.amount);
    final owedLitres = owed.fold(0.0, (t, s) => t + s.liters);
    return SectionCard(
      key: const ValueKey('milk-handover-card'),
      title: context.t('mhTitle'),
      subtitle: context.t('mhSubtitle'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.local_shipping_outlined, size: 20, color: FarmColors.cedar),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              routine.hasCollector ? '${context.t('mhCollector')}: ${routine.collectorName} · ${collectorPrice(routine)}' : context.t('mhNoCollector'),
              key: const ValueKey('milk-collector-line'),
              style: FarmTypography.textTheme.titleSmall,
            ),
          ),
          if (access.canSetMilkRoutine)
            TextButton.icon(
              key: const ValueKey('milk-routine'),
              onPressed: () => showMilkRoutineDialog(context),
              icon: const Icon(Icons.tune, size: 18),
              label: Text(context.t('mhCollectorSettings')),
            ),
        ]),
        const SizedBox(height: FarmSpacing.sm),
        if (shown.isEmpty)
          Text(context.t('mhNoMilkings'), style: FarmTypography.textTheme.bodySmall)
        else
          for (final m in shown) _MilkingRow(milking: m, canHandOver: access.canHandOverMilk),
        if (access.canHandOverMilk) ...[
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('handover-other'),
              onPressed: () => showHandOverDialog(context),
              icon: const Icon(Icons.edit_calendar_outlined, size: 18),
              label: Text(context.t('mhOtherMilking')),
            ),
          ),
        ],
        if (owed.isNotEmpty) ...[
          const Divider(height: 24, color: FarmColors.border),
          Row(children: [
            Expanded(
              child: Text(
                '${routine.collectorName} ${context.t('mhOwes')} ${money(owedAmount, 'USD')} · ${litres(owedLitres)} L · ${owed.length} ${context.t('mhCollections')}',
                key: const ValueKey('collector-owes'),
                style: FarmTypography.textTheme.titleSmall,
              ),
            ),
            if (access.canReceivePayment)
              FilledButton.icon(
                key: const ValueKey('collector-paid'),
                onPressed: () => showReceivePaymentDialog(context, buyer: routine.collectorName!),
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: Text(context.t('mhCollectorPaid')),
              ),
          ]),
        ],
      ]),
    );
  }

  static int _order(String s) => switch (s) { 'morning' => 0, 'midday' => 1, _ => 2 };
}

class _MilkingRow extends StatelessWidget {
  const _MilkingRow({required this.milking, required this.canHandOver});
  final MilkingHandover milking;
  final bool canHandOver;

  @override
  Widget build(BuildContext context) {
    final m = milking;
    final routine = context.watch<MilkSalesProvider>().routine;
    final pill = m.pending
        ? StatusPill(label: context.t('msWaitingSync'), level: FarmStatusLevel.neutral, dense: true)
        : !m.handedOver
            ? StatusPill(label: context.t('mhNotHandedOver'), level: FarmStatusLevel.watch, dense: true)
            : m.collectedL > 0
                ? StatusPill(label: context.t(m.paid ? 'msPaid' : 'msToBePaid'), level: m.paid ? FarmStatusLevel.good : FarmStatusLevel.watch, dense: true)
                : StatusPill(label: context.t('mhDone'), level: FarmStatusLevel.good, dense: true);
    return Container(
      key: ValueKey('milking-${m.day}-${m.session}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_dayLabel(context, m.day)} · ${milkSessionLabel(context, m.session)}', style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              [
                '${context.t('mhMilked')} ${litres(m.milkedL)} L',
                if (m.handedOver) '${context.t('mhCalves')} ${litres(m.calvesL)} L',
                if (m.handedOver) '${context.t('mhToCollector')} ${litres(m.collectedL)} L${m.amount > 0 ? ' · ${money(m.amount, 'USD')}' : ''}',
                if (m.handedOver && m.leftL >= 0.05) '${context.t('mhLeft')} ${litres(m.leftL)} L',
              ].join(' · '),
              style: FarmTypography.textTheme.bodySmall,
            ),
          ]),
        ),
        const SizedBox(width: 8),
        pill,
        if (!m.handedOver && canHandOver) ...[
          const SizedBox(width: 8),
          FilledButton(
            key: ValueKey('handover-${m.day}-${m.session}'),
            onPressed: () => showHandOverDialog(context, day: DateTime.parse(m.day), session: m.session),
            child: Text(context.t(routine.hasCollector ? 'mhHandOver' : 'mhCalvesOnly')),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------- hand over form
/// After a milking: litres to the calves, and litres the collector took —
/// sold to him at the agreed price, to be paid with the week.
Future<void> showHandOverDialog(BuildContext context, {DateTime? day, String? session}) =>
    showDialog<void>(context: context, builder: (_) => _HandOverDialog(day: day, session: session));

class _HandOverDialog extends StatefulWidget {
  const _HandOverDialog({this.day, this.session});
  final DateTime? day;
  final String? session;

  @override
  State<_HandOverDialog> createState() => _HandOverDialogState();
}

class _HandOverDialogState extends State<_HandOverDialog> {
  late DateTime _day = widget.day ?? DateTime.now();
  late String _session = widget.session ?? FarmClock.current.milkSessionNow();
  final _calves = TextEditingController();
  final _collected = TextEditingController();
  final _notes = TextEditingController();
  bool _collectedEdited = false;
  bool _anyway = false;
  bool _saving = false;
  String? _error;

  MilkingHandover? get _milking => context.read<MilkSalesProvider>().milkingOf(_iso(_day), _session);

  @override
  void initState() {
    super.initState();
    _calves.addListener(_fill);
    _collected.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _fill());
  }

  /// The collector takes what the calves do not, until someone types his litres.
  void _fill() {
    if (!mounted) return;
    final m = _milking;
    if (!_collectedEdited && m != null && context.read<MilkSalesProvider>().routine.hasCollector) {
      final calves = parseLocalizedDouble(_calves.text) ?? 0;
      final rest = (m.milkedL - m.calvesL - m.collectedL - calves).clamp(0, double.infinity).toDouble();
      final text = rest == 0 ? '' : litres(rest);
      if (_collected.text != text) _collected.text = text;
    }
    setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_calves, _collected, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final calves = parseLocalizedDouble(_calves.text) ?? 0;
    final collected = parseLocalizedDouble(_collected.text) ?? 0;
    final milk = context.read<MilkSalesProvider>();
    if (calves < 0 || collected < 0 || calves + collected <= 0) {
      setState(() => _error = context.t('mhSayLitres'));
      return;
    }
    final over = calves + collected > milk.tank.balanceL + 0.0005;
    final canOverride = context.read<AccessProvider>().canAdjustMilkTank;
    if (over && !(canOverride && _anyway)) {
      setState(() => _error = context.t(canOverride ? 'msOverTankConfirm' : 'msOverTank').replaceAll('{tank}', litres(milk.tank.balanceL < 0 ? 0 : milk.tank.balanceL)));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await milk.handOver(day: _day, session: _session, calvesL: calves, collectedL: collected, notes: _notes.text, allowNegative: over && _anyway);
    if (!mounted) return;
    if (result.success) {
      if (!result.queued) refreshMoney(context);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.queued
            ? context.t('msSavedOffline')
            : '${context.t('mhHandedOver')}: ${litres(calves)} L ${context.t('mhToCalvesShort')} · ${litres(collected)} L ${context.t('mhToCollectorShort')}'),
      ));
      return;
    }
    if (result.isPossibleDuplicate) {
      setState(() => _saving = false);
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final milk = context.watch<MilkSalesProvider>();
    final routine = milk.routine;
    final canOverride = context.watch<AccessProvider>().canAdjustMilkTank;
    final m = milk.milkingOf(_iso(_day), _session);
    final calves = parseLocalizedDouble(_calves.text) ?? 0;
    final collected = parseLocalizedDouble(_collected.text) ?? 0;
    final over = calves + collected > milk.tank.balanceL + 0.0005;
    return FarmFormDialog(
      title: Text(context.t('mhHandOverTitle')),
      width: 520,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          RecordDateButton(label: context.t('mhMilkingOf'), value: _day, maxDaysBack: 60, onPicked: (d) => setState(() {
            _day = d;
            _collectedEdited = false;
            WidgetsBinding.instance.addPostFrameCallback((_) => _fill());
          })),
          for (final s in const ['morning', 'evening'])
            ChoiceChip(
              key: ValueKey('handover-session-$s'),
              label: Text(milkSessionLabel(context, s)),
              selected: _session == s,
              onSelected: (_) => setState(() {
                _session = s;
                _collectedEdited = false;
                WidgetsBinding.instance.addPostFrameCallback((_) => _fill());
              }),
            ),
        ]),
        const SizedBox(height: 12),
        Container(
          key: const ValueKey('handover-milked'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: FarmColors.tint(FarmColors.milkBlue, 0.10), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${context.t('mhMilkedThisMilking')}: ${m == null ? '—' : '${litres(m.milkedL)} L'}', style: FarmTypography.textTheme.titleSmall),
            if (m != null && m.handedOver)
              Text('${context.t('mhAlreadyHandedOver')}: ${litres(m.calvesL)} L ${context.t('mhToCalvesShort')} · ${litres(m.collectedL)} L ${context.t('mhToCollectorShort')}',
                  style: FarmTypography.textTheme.bodySmall),
            Text('${context.t('msInTank')}: ${litres(milk.tank.balanceL)} L', style: FarmTypography.textTheme.bodySmall),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('handover-calves'),
          controller: _calves,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t('mhCalvesLitres'), suffixText: 'L'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('handover-collector'),
          controller: _collected,
          enabled: routine.hasCollector,
          onChanged: (_) => _collectedEdited = true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: routine.hasCollector ? '${context.t('mhCollectorLitres')} (${routine.collectorName})' : context.t('mhCollectorLitres'),
            suffixText: 'L',
            helperText: routine.hasCollector
                ? '${collectorPrice(routine)} → ${_collectorAmount(routine, collected)} · ${context.t('mhPaidWithWeek')}'
                : context.t('mhNoCollector'),
          ),
        ),
        if (over) ...[
          const SizedBox(height: 10),
          NoticeBanner(
            title: context.t('msOverTankTitle'),
            text: context.t(canOverride ? 'msOverTankManager' : 'msOverTank').replaceAll('{tank}', litres(milk.tank.balanceL < 0 ? 0 : milk.tank.balanceL)),
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
        const SizedBox(height: 12),
        TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('handover-save'),
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('mhHandOver')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------- routine settings
/// The farm manager's: the collector, his price per litre (USD or LBP) and
/// what the second milking is called.
Future<void> showMilkRoutineDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _MilkRoutineDialog());

class _MilkRoutineDialog extends StatefulWidget {
  const _MilkRoutineDialog();

  @override
  State<_MilkRoutineDialog> createState() => _MilkRoutineDialogState();
}

class _MilkRoutineDialogState extends State<_MilkRoutineDialog> {
  late final MilkRoutine _r = context.read<MilkSalesProvider>().routine;
  late final _name = TextEditingController(text: _r.collectorName ?? '');
  late final _price = TextEditingController(text: _r.collectorPrice == null ? '' : _r.collectorPrice!.toString());
  late String _currency = _r.collectorCurrency;
  late String _second = _r.secondMilking;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final price = parseLocalizedDouble(_price.text);
    if (_name.text.trim().isNotEmpty && (price == null || price <= 0)) {
      setState(() => _error = context.t('finSayPrice'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<MilkSalesProvider>().setRoutine(
          collectorName: _name.text,
          collectorPrice: price,
          collectorCurrency: _currency,
          secondMilking: _second,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('mhRoutineSaved'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FarmFormDialog(
      title: Text(context.t('mhRoutineTitle')),
      width: 480,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('mhSecondMilking'), style: FarmTypography.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          ChoiceChip(key: const ValueKey('routine-afternoon'), label: Text(context.t('sessionAfternoon')), selected: _second == 'afternoon',
              onSelected: (_) => setState(() => _second = 'afternoon')),
          ChoiceChip(key: const ValueKey('routine-evening'), label: Text(context.t('sessionEvening')), selected: _second == 'evening',
              onSelected: (_) => setState(() => _second = 'evening')),
        ]),
        const SizedBox(height: 16),
        TextField(key: const ValueKey('routine-name'), controller: _name, decoration: InputDecoration(labelText: context.t('mhCollectorName'))),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('routine-price'),
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t('mhCollectorPricePerL'), suffixText: '$_currency/L'),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(context.t('finCurrency'), style: FarmTypography.textTheme.labelMedium),
          for (final c in const ['USD', 'LBP'])
            ChoiceChip(key: ValueKey('routine-$c'), label: Text(c), selected: _currency == c, onSelected: (_) => setState(() => _currency = c)),
        ]),
        const SizedBox(height: 8),
        Text(context.t('mhRoutineHint'), style: FarmTypography.textTheme.bodySmall),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('routine-save'),
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }
}
