import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/finance.dart';
import '../../providers/access_provider.dart';
import '../../providers/finance_provider.dart';
import '../../providers/milk_sales_provider.dart';
import '../../providers/sales_provider.dart';
import '../production/milk_sales_ui.dart' show money, showSellMilkDialog;

/// "537,000" — whole numbers with thousands separators (LBP has no cents).
String grouped(double v) {
  final s = v.abs().round().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// An amount in USD, with the LBP it was agreed in: "$6.00 (537,000 LBP)".
String moneyWithOriginal(double usd, double? original, String? originalCurrency) =>
    original != null && originalCurrency != null && originalCurrency != 'USD' ? '${money(usd, 'USD')} (${grouped(original)} $originalCurrency)' : money(usd, 'USD');

String _d(DateTime d) => '${d.day}/${d.month}/${d.year}';

/// After money changed, the figures that show it reload.
void refreshMoney(BuildContext context) {
  for (final load in <void Function()>[
    () => context.read<SalesProvider>().load(),
    () => context.read<MilkSalesProvider>().load(),
  ]) {
    try {
      load();
    } catch (_) {
      // Not on this screen's tree.
    }
  }
}

// ------------------------------------------------------------- currency
/// USD or LBP for an amount, the rate (the farm's for the day, or the
/// one actually used) and what the amount comes to in USD.
class CurrencyChooser extends StatelessWidget {
  const CurrencyChooser({super.key, required this.currency, required this.onCurrency, required this.rate, required this.amount, required this.farmRate});

  final String currency;
  final ValueChanged<String> onCurrency;
  final TextEditingController rate;

  /// The amount entered, in [currency].
  final double? amount;
  final double? farmRate;

  @override
  Widget build(BuildContext context) {
    final r = parseLocalizedDouble(rate.text);
    final usd = currency == 'USD' ? amount : (amount != null && r != null && r > 0 ? amount! / r : null);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(context.t('finCurrency'), style: FarmTypography.textTheme.labelMedium),
        for (final c in const ['USD', 'LBP'])
          ChoiceChip(key: ValueKey('currency-$c'), label: Text(c), selected: currency == c, onSelected: (_) => onCurrency(c)),
      ]),
      if (currency == 'LBP') ...[
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('rate-field'),
          controller: rate,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: context.t('finRateUsed'),
            prefixText: '1 USD = ',
            suffixText: 'LBP',
            helperText: farmRate == null ? context.t('finNoRateSet') : '${context.t('finFarmRate')}: 1 USD = ${grouped(farmRate!)} LBP',
          ),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        key: const ValueKey('usd-equivalent'),
        usd == null ? '${context.t('finInUsd')}: —' : '${context.t('finInUsd')}: ${money(usd, 'USD')}',
        style: FarmTypography.textTheme.titleMedium,
      ),
    ]);
  }
}

Widget _nameChips(List<String> names, ValueChanged<String> onPick) => names.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(spacing: 6, runSpacing: 4, children: [for (final n in names) ActionChip(label: Text(n), onPressed: () => onPick(n))]),
      );

// ----------------------------------------------------------- record sale
const saleTypes = ['eggs', 'produce', 'animals', 'farm_products', 'other'];
const _unitsFor = {
  'eggs': ['tray', 'dozen', 'piece'],
  'produce': ['kg', 'crate', 'box', 'bunch'],
  'animals': ['head'],
  'farm_products': ['piece', 'kg', 'jar', 'L'],
  'other': ['piece', 'kg', 'L'],
};

/// Any product sold — eggs, vegetables, an animal, other farm products —
/// with its quantity and price in USD or LBP, the buyer, paid now or to be
/// paid. Milk is sold from the tank (Sell milk); Mouneh from its shop.
Future<void> showRecordSaleDialog(BuildContext context, {String type = 'eggs'}) =>
    showDialog<void>(context: context, builder: (_) => _RecordSaleDialog(initialType: type));

class _RecordSaleDialog extends StatefulWidget {
  const _RecordSaleDialog({required this.initialType});
  final String initialType;

  @override
  State<_RecordSaleDialog> createState() => _RecordSaleDialogState();
}

class _RecordSaleDialogState extends State<_RecordSaleDialog> {
  late String _type = widget.initialType;
  late final _label = TextEditingController(text: context.t('finProduct_$_type'));
  final _quantity = TextEditingController(text: '1');
  late String _unit = _unitsFor[_type]!.first;
  final _price = TextEditingController();
  late final _rate = TextEditingController(text: _rateText(context.read<FinanceProvider>().rates.lbpPerUsd));
  final _buyer = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  String _currency = 'USD';
  DateTime _day = DateTime.now();
  bool _paid = true;
  bool _saving = false;
  String? _error;

  static String _rateText(double? r) => r == null ? '' : r.toStringAsFixed(0);

  @override
  void initState() {
    super.initState();
    for (final c in [_quantity, _price, _rate]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_label, _quantity, _price, _rate, _buyer, _reference, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _setType(String t) => setState(() {
        if (_label.text.trim().isEmpty || _label.text == context.t('finProduct_$_type')) _label.text = context.t('finProduct_$t');
        _type = t;
        _unit = _unitsFor[t]!.first;
      });

  double? get _total {
    final q = parseLocalizedDouble(_quantity.text);
    final p = parseLocalizedDouble(_price.text);
    return q != null && p != null ? q * p : null;
  }

  Future<void> _submit() async {
    final q = parseLocalizedDouble(_quantity.text);
    final p = parseLocalizedDouble(_price.text);
    final rate = parseLocalizedDouble(_rate.text);
    String? problem;
    if (_label.text.trim().isEmpty) problem = context.t('finSayWhat');
    if (q == null || q <= 0) problem ??= context.t('finSayQuantity');
    if (p == null || p <= 0) problem ??= context.t('finSayPrice');
    if (_currency == 'LBP' && (rate == null || rate <= 0)) problem ??= context.t('finSayRate');
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FinanceProvider>().recordSale(
          productType: _type,
          productLabel: _label.text,
          quantity: q,
          unit: _unit,
          unitPrice: p,
          currency: _currency,
          exchangeRate: _currency == 'LBP' ? rate : null,
          soldAt: recordedInstant(_day),
          buyerName: _buyer.text,
          paid: _paid,
          reference: _reference.text,
          notes: _notes.text,
        );
    if (!mounted) return;
    if (result.success) {
      if (!result.queued) refreshMoney(context);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.queued ? context.t('finSavedOffline') : context.t('finSaleSaved'))));
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
    final finance = context.watch<FinanceProvider>();
    final access = context.watch<AccessProvider>();
    return FarmFormDialog(
      title: Text(context.t('finRecordSale')),
      width: 560,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('finWhatSold'), style: FarmTypography.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final t in saleTypes)
            ChoiceChip(key: ValueKey('sale-type-$t'), label: Text(context.t('finProduct_$t')), selected: _type == t, onSelected: (_) => _setType(t)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text(context.t('finMilkMounehElsewhere'), style: FarmTypography.textTheme.bodySmall)),
          if (access.canSellMilk)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                showSellMilkDialog(context);
              },
              child: Text(context.t('msSellMilk')),
            ),
        ]),
        const SizedBox(height: 10),
        TextField(key: const ValueKey('sale-label'), controller: _label, decoration: InputDecoration(labelText: context.t('finProductName'))),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: RecordDateButton(label: context.t('msSoldOn'), value: _day, maxDaysBack: 365, onPicked: (d) => setState(() => _day = d)),
        ),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('sale-quantity'),
              controller: _quantity,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: context.t('quantity')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('sale-unit-$_type'),
              initialValue: _unit,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('rpUnit')),
              items: [for (final u in _unitsFor[_type]!) DropdownMenuItem(value: u, child: Text(context.t('finUnit_$u')))],
              onChanged: (u) => setState(() => _unit = u ?? _unit),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('sale-price'),
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t('finPricePerUnit'), suffixText: _currency),
        ),
        const SizedBox(height: 8),
        Text(
          key: const ValueKey('sale-total'),
          _total == null ? '${context.t('msTotal')}: —' : '${context.t('msTotal')}: ${_currency == 'USD' ? money(_total!, 'USD') : '${grouped(_total!)} LBP'}',
          style: FarmTypography.textTheme.titleSmall,
        ),
        const SizedBox(height: 10),
        CurrencyChooser(currency: _currency, onCurrency: (c) => setState(() => _currency = c), rate: _rate, amount: _total, farmRate: finance.rates.lbpPerUsd),
        const SizedBox(height: 14),
        TextField(key: const ValueKey('sale-buyer'), controller: _buyer, decoration: InputDecoration(labelText: context.t('msBuyer'), hintText: context.t('optional'))),
        _nameChips(finance.recentBuyers, (n) => setState(() => _buyer.text = n)),
        const SizedBox(height: 14),
        Text(context.t('msPayment'), style: FarmTypography.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          ChoiceChip(key: const ValueKey('sale-paid'), label: Text(context.t('msPaidNow')), selected: _paid, onSelected: (_) => setState(() => _paid = true)),
          ChoiceChip(key: const ValueKey('sale-pending'), label: Text(context.t('msToBePaid')), selected: !_paid, onSelected: (_) => setState(() => _paid = false)),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('msReference'), hintText: context.t('optional'))),
        const SizedBox(height: 10),
        TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('sale-save'),
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('msSaveSale')),
        ),
      ],
    );
  }
}

// -------------------------------------------------------- record expense
const expenseCategories = ['feed', 'medicine', 'veterinary', 'labor', 'fuel', 'utilities', 'equipment', 'repairs', 'transport', 'rent', 'taxes',
  'packaging', 'seeds', 'fertilizer', 'other'];

/// An expense paid, or a bill still to pay (with its due date): what for,
/// how much in USD or LBP, to whom. Feed and medicine received into stock
/// are already counted from their deliveries.
Future<void> showRecordExpenseDialog(BuildContext context, {String category = 'fuel'}) =>
    showDialog<void>(context: context, builder: (_) => _RecordExpenseDialog(initialCategory: category));

class _RecordExpenseDialog extends StatefulWidget {
  const _RecordExpenseDialog({required this.initialCategory});
  final String initialCategory;

  @override
  State<_RecordExpenseDialog> createState() => _RecordExpenseDialogState();
}

class _RecordExpenseDialogState extends State<_RecordExpenseDialog> {
  late String _category = widget.initialCategory;
  final _description = TextEditingController();
  final _amount = TextEditingController();
  late final _rate = TextEditingController(text: _RecordSaleDialogState._rateText(context.read<FinanceProvider>().rates.lbpPerUsd));
  final _supplier = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  String _currency = 'USD';
  DateTime _day = DateTime.now();
  DateTime _due = DateTime.now().add(const Duration(days: 30));
  bool _paid = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_amount, _rate]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_description, _amount, _rate, _supplier, _reference, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _due,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 730)),
      helpText: context.t('finDueDate'),
    );
    if (picked != null) setState(() => _due = picked);
  }

  Future<void> _submit() async {
    final amount = parseLocalizedDouble(_amount.text);
    final rate = parseLocalizedDouble(_rate.text);
    String? problem;
    if (amount == null || amount <= 0) problem = context.t('finSayAmount');
    if (_currency == 'LBP' && (rate == null || rate <= 0)) problem ??= context.t('finSayRate');
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FinanceProvider>().recordExpense(
          category: _category,
          description: _description.text,
          amount: amount!,
          currency: _currency,
          exchangeRate: _currency == 'LBP' ? rate : null,
          incurredAt: recordedInstant(_day),
          supplierName: _supplier.text,
          paid: _paid,
          dueDate: _paid ? null : _due,
          reference: _reference.text,
          notes: _notes.text,
        );
    if (!mounted) return;
    if (result.success) {
      if (!result.queued) refreshMoney(context);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.queued ? context.t('finSavedOffline') : context.t('finExpenseSaved'))));
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
    final finance = context.watch<FinanceProvider>();
    return FarmFormDialog(
      title: Text(context.t('finRecordExpense')),
      width: 560,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('rpCategory'), style: FarmTypography.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final c in expenseCategories)
            ChoiceChip(key: ValueKey('expense-cat-$c'), label: Text(context.t('expense_$c')), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
        ]),
        if (_category == 'feed' || _category == 'medicine') ...[
          const SizedBox(height: 10),
          NoticeBanner(key: const ValueKey('expense-stock-notice'), text: context.t('finStockCountedNotice')),
        ],
        const SizedBox(height: 12),
        TextField(key: const ValueKey('expense-description'), controller: _description, decoration: InputDecoration(labelText: context.t('finWhatFor'))),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: RecordDateButton(label: context.t('finSpentOn'), value: _day, maxDaysBack: 365, onPicked: (d) => setState(() => _day = d)),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('expense-amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t('rpAmount'), suffixText: _currency),
        ),
        const SizedBox(height: 10),
        CurrencyChooser(
            currency: _currency, onCurrency: (c) => setState(() => _currency = c), rate: _rate, amount: parseLocalizedDouble(_amount.text), farmRate: finance.rates.lbpPerUsd),
        const SizedBox(height: 14),
        TextField(key: const ValueKey('expense-supplier'), controller: _supplier, decoration: InputDecoration(labelText: context.t('finPaidTo'), hintText: context.t('optional'))),
        _nameChips(finance.recentSuppliers, (n) => setState(() => _supplier.text = n)),
        const SizedBox(height: 14),
        Text(context.t('msPayment'), style: FarmTypography.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(key: const ValueKey('expense-paid'), label: Text(context.t('finPaid')), selected: _paid, onSelected: (_) => setState(() => _paid = true)),
          ChoiceChip(key: const ValueKey('expense-pending'), label: Text(context.t('finBillToPay')), selected: !_paid, onSelected: (_) => setState(() => _paid = false)),
          if (!_paid)
            OutlinedButton.icon(
              key: const ValueKey('expense-due'),
              onPressed: _pickDue,
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text('${context.t('finDueDate')}: ${_d(_due)}'),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('finInvoiceNo'), hintText: context.t('optional'))),
        const SizedBox(height: 10),
        TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('expense-save'),
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- the rate
/// The farm manager's: "1 USD = 89,500 LBP from a chosen date". A new rate starts
/// from its date; the ones before stay for the days they covered.
Future<void> showExchangeRateDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _ExchangeRateDialog());

class _ExchangeRateDialog extends StatefulWidget {
  const _ExchangeRateDialog();

  @override
  State<_ExchangeRateDialog> createState() => _ExchangeRateDialogState();
}

class _ExchangeRateDialogState extends State<_ExchangeRateDialog> {
  late final _rate = TextEditingController(text: _RecordSaleDialogState._rateText(context.read<FinanceProvider>().rates.lbpPerUsd));
  final _notes = TextEditingController();
  DateTime _since = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _rate.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final r = parseLocalizedDouble(_rate.text);
    if (r == null || r <= 0) {
      setState(() => _error = context.t('finSayRate'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FinanceProvider>().setRate(lbpPerUsd: r, since: _since, notes: _notes.text);
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.t('finRateSaved')}: 1 USD = ${grouped(r)} LBP')));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rates = context.watch<FinanceProvider>().rates;
    final canSet = context.watch<AccessProvider>().canSetExchangeRate;
    return FarmFormDialog(
      title: Text(context.t('finExchangeRate')),
      width: 480,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          rates.lbpPerUsd == null
              ? context.t('finNoRateSet')
              : '${context.t('finFarmRate')}: 1 USD = ${grouped(rates.lbpPerUsd!)} LBP${rates.lbpSince == null ? '' : ' · ${context.t('finSince')} ${_d(rates.lbpSince!)}'}',
          style: FarmTypography.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text(context.t('finRateHint'), style: FarmTypography.textTheme.bodySmall),
        if (canSet) ...[
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('exchange-rate-field'),
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(prefixText: '1 USD = ', suffixText: 'LBP'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: RecordDateButton(label: context.t('finRateFrom'), value: _since, maxDaysBack: 365, onPicked: (d) => setState(() => _since = d)),
          ),
          const SizedBox(height: 12),
          TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
        ],
        if (rates.history.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(context.t('finRateHistory'), style: FarmTypography.textTheme.labelMedium),
          const SizedBox(height: 4),
          for (final h in rates.history.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('${_d(h.since)} · 1 USD = ${grouped(h.rate)} LBP${h.notes == null ? '' : ' · ${h.notes}'}', style: FarmTypography.textTheme.bodySmall),
            ),
        ],
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t(canSet ? 'cancel' : 'close'))),
        if (canSet)
          FilledButton(
            key: const ValueKey('exchange-rate-save'),
            onPressed: _saving ? null : _submit,
            child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
          ),
      ],
    );
  }
}

/// A sale's or expense's money as a row reads it.
String financeAmount(FinanceSale s) => moneyWithOriginal(s.amount, s.originalAmount, s.originalCurrency);
String expenseAmount(FinanceExpense e) => moneyWithOriginal(e.amount, e.originalAmount, e.originalCurrency);
