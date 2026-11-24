import 'package:flutter/widgets.dart';
import '../../core/i18n/strings.dart';
import 'report_export.dart';

/// A code from the server ("labor", "farm_products") in the person's
/// language — the `prefix + code` string when there is one, else the code
/// made readable.
String codeLabel(BuildContext context, String prefix, String code) {
  if (code.isEmpty) return '—';
  final key = '$prefix$code';
  final label = context.t(key);
  if (label != key) return label;
  return code.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}

/// Turns a report the server worked out (backend farm_reports_service.py)
/// into figures and tables in the person's language. The same [ReportDoc]
/// is drawn on screen, saved as a spreadsheet and printed.
ReportDoc buildReportDoc(BuildContext context, String kind, Map<String, dynamic> data, {required String Function(String code) speciesName}) {
  final t = context.t;
  final currency = data['currency'] as String? ?? 'USD';
  final kpis = (data['kpis'] as Map?)?.cast<String, dynamic>() ?? const {};
  String n(Object? v, {int digits = 1}) {
    if (v == null) return '—';
    final d = (v as num).toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(digits);
  }

  String m(Object? v) {
    if (v == null) return '—';
    final d = (v as num).toDouble();
    final s = d.abs() >= 1000 ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
    return currency == 'USD' ? '\$$s' : '$s $currency';
  }

  String date(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '—' : '${d.day}/${d.month}/${d.year}';
  }

  String code(String prefix, Object? c) => codeLabel(context, prefix, '${c ?? ''}');

  // What the farm server names a milk sale (milk_sales_service.py), in
  // the person's language; anything else is a name someone typed.
  String product(Object? label) => switch ('${label ?? ''}') {
        'Raw milk' => t('msRawMilk'),
        'Raw milk (cancelled sale)' => t('msRawMilkCancelled'),
        '' => '—',
        final other => other,
      };

  List<Map<String, dynamic>> rows(String key) => [for (final r in (data[key] as List<dynamic>? ?? const [])) (r as Map).cast<String, dynamic>()];
  final start = data['start'] as String?;
  final end = data['end'] as String?;
  final period = '${t('rpPeriod')}: ${date(start)} – ${date(end)} (${data['days'] ?? '—'} ${t('rpDays')})';
  final stem = 'origami-$kind-${start ?? ''}_${end ?? ''}';
  final money = kpis.containsKey('revenue');

  switch (kind) {
    case 'milk':
      final byDay = rows('by_day');
      final midday = byDay.any((d) => ((d['midday'] as num?) ?? 0) > 0);
      return ReportDoc(
        title: t('rpMilkReport'),
        period: period,
        fileStem: stem,
        kpis: [
          (t('rpMilkTotal'), '${n(kpis['total_l'])} L'),
          (t('rpPerDay'), '${n(kpis['avg_per_day_l'])} L'),
          (t('rpAnimalsMilked'), n(kpis['animals_milked'])),
          (t('rpPerAnimalDay'), '${n(kpis['avg_per_animal_day_l'])} L'),
          (t('rpWithheld'), '${n(kpis['withheld_l'])} L'),
          if (money) ...[
            (t('rpMilkSold'), '${n(kpis['sold_l'])} L'),
            (t('rpRevenue'), m(kpis['revenue'])),
            (t('rpAvgPrice'), kpis['avg_price_per_liter'] == null ? '—' : '${m(kpis['avg_price_per_liter'])}/L'),
            (t('msUnpaid'), m(kpis['pending_amount'])),
          ],
          (t('msInTank'), '${n(kpis['tank_now_l'])} L'),
        ],
        tables: [
          ReportTable(
            title: t('rpPerDayTable'),
            columns: [t('rpDate'), t('sessionMorning'), if (midday) t('sessionMidday'), t('sessionEvening'), t('rpTotalL'), t('rpSoldL')],
            numeric: {1, 2, 3, 4, if (midday) 5},
            rows: [
              for (final d in byDay.reversed)
                [date(d['date']), n(d['morning']), if (midday) n(d['midday']), n(d['evening']), n(d['total']), n(d['sold'])],
            ],
          ),
          ReportTable(
            title: t('rpPerAnimal'),
            columns: [t('rpAnimal'), t('rpMilkings'), t('rpDaysMilked'), t('rpTotalL'), t('rpAvgDayL'), t('rpBestDayL')],
            numeric: {1, 2, 3, 4, 5},
            flex: const [3, 1, 1, 1, 1, 1],
            rows: [
              for (final a in rows('by_animal'))
                [[if ((a['tag'] as String?)?.isNotEmpty ?? false) a['tag'], a['name']].join(' · '), n(a['milkings']), n(a['days_milked']), n(a['total_l']), n(a['avg_per_day_l']), n(a['best_day_l'])],
            ],
          ),
          ReportTable(
            title: t('rpWhereMilkWent'),
            columns: [t('destination'), t('rpLiters')],
            numeric: {1},
            rows: [for (final d in rows('destinations')) [t('${d['destination']}'), n(d['liters'])]],
          ),
          if (money) ...[
            ReportTable(
              title: t('rpMilkSales'),
              columns: [t('rpDate'), t('msBuyer'), t('rpLiters'), t('msPricePerLiter'), t('rpAmount'), t('msPayment')],
              numeric: {2, 3, 4},
              flex: const [2, 3, 1, 1, 1, 2],
              rows: [
                for (final s in rows('sales').reversed)
                  [date(s['date']), '${s['buyer'] ?? '—'}', n(s['liters']), m(s['price_per_liter']), m(s['amount']), t(s['payment_status'] == 'paid' ? 'msPaid' : 'msToBePaid')],
              ],
            ),
            ReportTable(
              title: t('rpByBuyer'),
              columns: [t('msBuyer'), t('rpSales'), t('rpLiters'), t('rpAmount'), t('msUnpaid')],
              numeric: {1, 2, 3, 4},
              flex: const [3, 1, 1, 1, 1],
              rows: [for (final b in rows('by_buyer')) ['${b['buyer'] ?? '—'}', n(b['sales']), n(b['liters']), m(b['amount']), m(b['pending'])]],
            ),
          ],
        ],
      );
    case 'feed':
      return ReportDoc(
        title: t('rpFeedReport'),
        period: period,
        fileStem: stem,
        kpis: [
          (t('rpFeedings'), n(kpis['feedings'])),
          (t('rpSubjectsFed'), n(kpis['subjects_fed'])),
          (t('rpFeedUsed'), '${n(kpis['feed_used_kg'])} kg'),
          (t('rpFeedCost'), m(kpis['feed_cost'])),
          (t('rpDeliveries'), '${n(kpis['deliveries'])} · ${n(kpis['delivered_kg'])} kg'),
          (t('rpDeliveredCost'), m(kpis['delivered_cost'])),
          (t('rpMixes'), '${n(kpis['mixes'])} · ${n(kpis['mixed_kg'])} kg'),
        ],
        tables: [
          ReportTable(
            title: t('rpFeedUsedTable'),
            columns: [t('rpFeed'), t('quantity'), t('rpUnit'), t('rpFeedings'), t('rpCost')],
            numeric: {1, 3, 4},
            flex: const [3, 1, 1, 1, 1],
            rows: [for (final u in rows('used')) ['${u['name']}', n(u['quantity']), '${u['unit']}', n(u['feedings']), m(u['cost'])]],
          ),
          ReportTable(
            title: t('rpDeliveriesTable'),
            columns: [t('rpDate'), t('rpFeed'), t('quantity'), t('supplier'), t('rpCost')],
            numeric: {2, 4},
            flex: const [2, 3, 2, 2, 1],
            rows: [
              for (final d in rows('deliveries').reversed)
                [date(d['date']), '${d['name']}', '${n(d['quantity'])} ${d['unit']}', '${d['supplier'] ?? '—'}', m(d['cost'])],
            ],
          ),
          ReportTable(
            title: t('rpMixesTable'),
            columns: [t('rpMix'), t('rpDate'), t('rpFeed'), t('quantity'), t('rpCost')],
            numeric: {3, 4},
            flex: const [2, 2, 3, 1, 1],
            rows: [for (final x in rows('mixes').reversed) ['${x['mix_code']}', date(x['date']), '${x['name']}', '${n(x['quantity'])} ${x['unit']}', m(x['cost'])]],
          ),
          ReportTable(
            title: t('rpStockNow'),
            columns: [t('rpFeed'), t('rpOnHand'), t('rpAvailable'), t('rpPerDayUse'), t('rpDaysCover')],
            numeric: {1, 2, 3, 4},
            flex: const [3, 1, 1, 1, 1],
            rows: [
              for (final s in rows('stock'))
                ['${s['name']}', '${n(s['on_hand'])} ${s['unit']}', '${n(s['available'])} ${s['unit']}', s['daily_demand'] == null ? '—' : n(s['daily_demand']),
                 s['days_of_cover'] == null ? '—' : n(s['days_of_cover'])],
            ],
          ),
        ],
      );
    case 'herd':
      return ReportDoc(
        title: t('rpHerdReport'),
        period: period,
        fileStem: stem,
        kpis: [
          (t('rpOnFarm'), n(kpis['on_farm'])),
          (t('rpInMilk'), n(kpis['in_milk'])),
          (t('rpPregnant'), n(kpis['pregnant'])),
          (t('rpBirths'), '${n(kpis['births'])} · ${n(kpis['born_alive'])} ${t('rpBornAlive')}'),
          (t('rpAdded'), n(kpis['added'])),
          (t('rpLeft'), n(kpis['exits'])),
          (t('rpHealthCases'), '${n(kpis['health_cases'])} · ${n(kpis['health_cases_open'])} ${t('rpOpen')}'),
        ],
        tables: [
          ReportTable(
            title: t('rpBySpecies'),
            columns: [t('rpSpecies'), t('rpOnFarm'), t('rpFemales'), t('rpMales'), t('rpInMilk'), t('rpPregnant')],
            numeric: {1, 2, 3, 4, 5},
            flex: const [2, 1, 1, 1, 1, 1],
            rows: [
              for (final s in rows('by_species'))
                [speciesName('${s['species']}'), n(s['on_farm']), n(s['females']), n(s['males']), n(s['in_milk']), n(s['pregnant'])],
            ],
          ),
          ReportTable(
            title: t('rpBirthsTable'),
            columns: [t('rpDate'), t('rpMother'), t('rpBorn'), t('rpAlive'), t('rpStillborn')],
            numeric: {2, 3, 4},
            flex: const [2, 3, 1, 1, 1],
            rows: [
              for (final b in rows('births').reversed)
                [date(b['date']), [if ((b['dam_tag'] as String?)?.isNotEmpty ?? false) b['dam_tag'], b['dam']].join(' · '), n(b['born']), n(b['alive']), n(b['stillborn'])],
            ],
          ),
          ReportTable(
            title: t('rpLeftTable'),
            columns: [t('rpDate'), t('rpAnimal'), t('rpSpecies'), t('rpHow')],
            flex: const [2, 3, 2, 2],
            rows: [
              for (final x in rows('exits').reversed)
                [date(x['date']), [if ((x['tag'] as String?)?.isNotEmpty ?? false) x['tag'], x['name']].join(' · '), speciesName('${x['species']}'), code('exit_', x['status'])],
            ],
          ),
        ],
      );
    case 'sales':
      String qtyUnit(Object? q, Object? unit) {
        if (q == null) return '—';
        final u = '${unit ?? ''}';
        final key = 'finUnit_$u';
        final label = t(key);
        return '${n(q, digits: 2)} ${label == key ? u : label}'.trim();
      }
      String amountWithOriginal(Map<String, dynamic> x) {
        final o = x['original_amount'];
        final c = x['original_currency'];
        return o != null && c != null && c != 'USD' ? '${m(x['amount'])} (${n(o, digits: 0)} $c)' : m(x['amount']);
      }
      String state(Map<String, dynamic> x) => switch ('${x['status']}') {
            'cancelled' => t('msCancelled'),
            'reversal' => t('finReversal'),
            _ => t(x['payment_status'] == 'paid' ? 'msPaid' : 'msToBePaid'),
          };
      return ReportDoc(
        title: t('rpSalesReport'),
        period: period,
        fileStem: stem,
        kpis: [
          (t('rpSales'), n(kpis['sales'])),
          (t('rpRevenue'), m(kpis['revenue'])),
          (t('rpPaidAmount'), m(kpis['paid'])),
          (t('msUnpaid'), m(kpis['unpaid'])),
          (t('rpAvgSale'), m(kpis['average_sale'])),
          (t('rpBuyers'), n(kpis['buyers'])),
          (t('rpCancelledSales'), n(kpis['cancelled'])),
        ],
        tables: [
          ReportTable(
            title: t('rpWhatWasSold'),
            columns: [t('rpProduct'), t('quantity'), t('rpAvgPrice'), t('rpAmount'), t('rpSales')],
            numeric: {1, 2, 3, 4},
            flex: const [3, 2, 1, 1, 1],
            rows: [
              for (final p in rows('by_product'))
                [product(p['product']), qtyUnit(p['quantity'], p['unit']), p['average_price'] == null ? '—' : m(p['average_price']), m(p['amount']), n(p['sales'])],
            ],
          ),
          ReportTable(
            title: t('finByActivity'),
            columns: [t('finActivity'), t('rpAmount')],
            numeric: {1},
            rows: [for (final a in rows('by_activity')) [code('finActivity_', a['activity']), m(a['amount'])]],
          ),
          ReportTable(
            title: t('rpByBuyer'),
            columns: [t('msBuyer'), t('rpSales'), t('rpAmount'), t('msUnpaid')],
            numeric: {1, 2, 3},
            flex: const [3, 1, 1, 1],
            rows: [for (final b in rows('by_buyer')) ['${b['buyer'] ?? t('finNoName')}', n(b['sales']), m(b['amount']), m(b['unpaid'])]],
          ),
          ReportTable(
            title: t('rpStillOwed'),
            columns: [t('rpDate'), t('rpProduct'), t('msBuyer'), t('rpAmount'), t('rpDaysWaiting')],
            numeric: {3, 4},
            flex: const [2, 3, 3, 1, 1],
            rows: [for (final u in rows('unpaid')) [date(u['date']), product(u['product']), '${u['buyer'] ?? '—'}', m(u['amount']), n(u['days'])]],
          ),
          ReportTable(
            title: t('rpEverySale'),
            columns: [t('rpDate'), t('rpProduct'), t('quantity'), t('rpAmount'), t('msBuyer'), t('msPayment')],
            numeric: {2, 3},
            flex: const [2, 3, 2, 2, 2, 2],
            rows: [
              for (final x in rows('sales').reversed)
                [date(x['date']), product(x['product']), qtyUnit(x['quantity'], x['unit']), amountWithOriginal(x), '${x['buyer'] ?? '—'}', state(x)],
            ],
          ),
        ],
      );
    case 'stock':
      final sections = {for (final x in (data['sections'] as List<dynamic>? ?? const [])) '$x'};
      final values = kpis['value'] != null;
      String low(Object? flag) => flag == true ? t('rpLow') : '';
      final milk = (data['milk'] as Map?)?.cast<String, dynamic>();
      return ReportDoc(
        title: t('rpStockReport'),
        period: '${t('rpAsOf')}: ${date(data['as_of'])}',
        fileStem: 'origami-stock-${data['as_of'] ?? ''}',
        kpis: [
          (t('rpStockLines'), n(kpis['lines'])),
          (t('rpLowStock'), n(kpis['low'])),
          (t('rpExpiringSoon'), n(kpis['expiring'])),
          if (sections.contains('milk')) (t('msInTank'), '${n(kpis['milk_in_tank_l'])} L'),
          if (values) (t('rpStockValue'), m(kpis['value'])),
        ],
        tables: [
          if (sections.contains('feed'))
            ReportTable(
              title: t('rpFeedStock'),
              columns: [t('rpFeed'), t('rpOnHand'), t('rpAvailable'), t('rpDaysCover'), if (values) t('rpValue'), t('rpState')],
              numeric: {1, 2, 3, if (values) 4},
              flex: [3, 2, 2, 1, if (values) 1, 1],
              rows: [
                for (final f in rows('feed'))
                  ['${f['name']}', '${n(f['on_hand'])} ${f['unit']}', '${n(f['available'])} ${f['unit']}', f['days_of_cover'] == null ? '—' : n(f['days_of_cover']),
                   if (values) m(f['value']), low(f['low'])],
              ],
            ),
          if (sections.contains('medicine'))
            ReportTable(
              title: t('rpMedicineStock'),
              columns: [t('rpMedicine'), t('rpOnHand'), t('rpUsable'), t('rpExpiringSoon'), t('rpFirstExpiry'), if (values) t('rpValue'), t('rpState')],
              numeric: {1, 2, 3, if (values) 5},
              flex: [3, 1, 1, 1, 2, if (values) 1, 1],
              rows: [
                for (final x in rows('medicine'))
                  ['${x['name']}', '${n(x['on_hand'], digits: 2)} ${x['unit'] ?? ''}'.trim(), n(x['usable'], digits: 2), n(x['expiring_soon'], digits: 2),
                   date(x['earliest_expiry']), if (values) m(x['value']), low(x['low'])],
              ],
            ),
          if (sections.contains('mouneh_goods'))
            ReportTable(
              title: t('rpMounehStock'),
              columns: [t('rpProduct'), t('rpAvailable'), t('rpReserved'), t('rpSold'), t('rpFirstExpiry'), if (values) t('rpValue'), t('rpState')],
              numeric: {1, 2, 3, if (values) 5},
              flex: [3, 1, 1, 1, 2, if (values) 1, 1],
              rows: [
                for (final x in rows('mouneh_goods'))
                  ['${x['name']}', '${n(x['available'])} ${x['unit'] ?? ''}'.trim(), n(x['reserved']), n(x['sold']), date(x['earliest_expiry']),
                   if (values) m(x['value']), low(x['low'])],
              ],
            ),
          if (sections.contains('mouneh_materials'))
            ReportTable(
              title: t('rpMaterialsStock'),
              columns: [t('rpMaterial'), t('rpOnHand'), if (values) t('rpValue'), t('rpState')],
              numeric: {1, if (values) 2},
              flex: [3, 2, if (values) 1, 1],
              rows: [for (final x in rows('mouneh_materials')) ['${x['name']}', '${n(x['on_hand'], digits: 2)} ${x['unit']}', if (values) m(x['value']), low(x['low'])]],
            ),
          if (sections.contains('milk') && milk != null)
            ReportTable(
              title: t('rpMilkStock'),
              columns: [t('msInTank'), if (values) t('msLastPrice'), if (values) t('rpValue')],
              numeric: {0, if (values) 1, if (values) 2},
              rows: [
                ['${n(milk['in_tank_l'])} L', if (values) (milk['last_price_per_liter'] == null ? '—' : '${m(milk['last_price_per_liter'])}/L'), if (values) m(milk['value'])],
              ],
            ),
          if (sections.contains('other'))
            ReportTable(
              title: t('rpOtherStock'),
              columns: [t('rpItem'), t('rpCategory'), t('rpOnHand'), t('rpReorderAt'), if (values) t('rpValue'), t('rpState')],
              numeric: {2, 3, if (values) 4},
              flex: [3, 2, 2, 1, if (values) 1, 1],
              rows: [
                for (final x in rows('other'))
                  ['${x['name']}', '${x['category'] ?? '—'}', '${n(x['on_hand'], digits: 2)} ${x['unit']}', n(x['reorder_level']), if (values) m(x['value']), low(x['low'])],
              ],
            ),
        ],
      );
    default:
      final byDay = [for (final d in rows('by_day')) if (((d['revenue'] as num?) ?? 0) != 0 || ((d['expenses'] as num?) ?? 0) != 0) d];
      return ReportDoc(
        title: t('rpFinanceReport'),
        period: period,
        fileStem: stem,
        kpis: [
          (t('rpRevenue'), m(kpis['revenue'])),
          (t('rpExpenses'), m(kpis['expenses'])),
          (t('rpMargin'), m(kpis['margin'])),
          (t('rpCashCollected'), m(kpis['cash_collected'])),
          (t('msUnpaid'), m(kpis['pending'])),
          (t('rpSales'), n(kpis['sales'])),
        ],
        tables: [
          ReportTable(
            title: t('rpRevenueByProduct'),
            columns: [t('rpProduct'), t('quantity'), t('rpAmount')],
            numeric: {1, 2},
            flex: const [3, 1, 1],
            rows: [for (final p in rows('revenue_by_product')) [product(p['product']), '${n(p['quantity'])} ${p['unit'] ?? ''}'.trim(), m(p['amount'])]],
          ),
          ReportTable(
            title: t('rpExpensesByCategory'),
            columns: [t('rpCategory'), t('rpAmount')],
            numeric: {1},
            rows: [for (final e in rows('expenses_by_category')) [code('expense_', e['category']), m(e['amount'])]],
          ),
          ReportTable(
            title: t('rpPerDayTable'),
            columns: [t('rpDate'), t('rpRevenue'), t('rpExpenses'), t('rpMargin')],
            numeric: {1, 2, 3},
            rows: [for (final d in byDay.reversed) [date(d['date']), m(d['revenue']), m(d['expenses']), m(d['margin'])]],
          ),
          ReportTable(
            title: t('rpSalesTable'),
            columns: [t('rpDate'), t('rpProduct'), t('quantity'), t('rpAmount'), t('msPayment')],
            numeric: {2, 3},
            flex: const [2, 3, 1, 1, 2],
            rows: [
              for (final s in rows('sales').reversed)
                [date(s['date']), product(s['product']), s['quantity'] == null ? '—' : '${n(s['quantity'])} ${s['unit'] ?? ''}'.trim(), m(s['amount']),
                 t(s['payment_status'] == 'paid' ? 'msPaid' : 'msToBePaid')],
            ],
          ),
        ],
      );
  }
}
