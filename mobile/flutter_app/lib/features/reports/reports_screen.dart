import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/bar_trend_chart.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/module_workspace.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../providers/access_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/reports_provider.dart';
import 'report_docs.dart';
import 'report_export.dart';

/// The reports a person can read, in this order (backend GET /reports/{kind}).
const reportKinds = ['milk', 'feed', 'herd', 'finance'];

const _kindLabels = {'milk': 'rpTabMilk', 'feed': 'rpTabFeed', 'herd': 'rpTabHerd', 'finance': 'rpTabFinance'};

/// Opens the Reports page on report [kind] — from the Milk page, the
/// animals list, the feed stock, Sales & Finance.
Future<void> openReport(BuildContext context, String kind) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: FarmColors.stone,
        appBar: AppBar(backgroundColor: FarmColors.stone, title: Text(context.t('navReports'))),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.md),
            child: ReportsScreen(initialKind: kind),
          ),
        ),
      ),
    ));

enum ReportPreset { last7, last30, thisMonth, lastMonth, custom }

/// Reports: milk, feed, the herd and the money, for a chosen period —
/// worked out by the farm server from the records themselves, shown here,
/// printed or saved as a PDF, or exported as a spreadsheet (CSV).
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.initialKind, this.today});

  final String? initialKind;

  /// The farm day the periods count back from (tests); today otherwise.
  final DateTime? today;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late String? _kind = widget.initialKind;
  ReportPreset _preset = ReportPreset.last30;
  late ReportPeriod _period = ReportPeriod.lastDays(30, today: widget.today);
  final Map<String, List<GlobalKey>> _keys = {};
  bool _exporting = false;

  /// The reports fetched since the page was last shown. A report is worked
  /// out again each time the page is opened or comes back into view (the
  /// menu keeps it alive, hidden, from sign-in): a sale or a milking
  /// recorded in between is in it. While the page stays in view, going back
  /// to a tab or period already fetched shows that answer; Refresh asks again.
  final Set<String> _fetched = {};
  bool _wasVisible = false;

  /// The painted blocks of report [kind], for the PDF.
  List<GlobalKey> _blocksFor(String kind, int count) {
    final keys = _keys.putIfAbsent(kind, () => []);
    while (keys.length < count) {
      keys.add(GlobalKey(debugLabel: 'report-$kind-${keys.length}'));
    }
    return keys.sublist(0, count);
  }

  void _setPreset(ReportPreset preset) {
    final today = widget.today;
    setState(() {
      _preset = preset;
      _period = switch (preset) {
        ReportPreset.last7 => ReportPeriod.lastDays(7, today: today),
        ReportPreset.last30 => ReportPeriod.lastDays(30, today: today),
        ReportPreset.thisMonth => ReportPeriod.thisMonth(today: today),
        ReportPreset.lastMonth => ReportPeriod.lastMonth(today: today),
        ReportPreset.custom => _period,
      };
    });
  }

  Future<void> _pickRange() async {
    final now = widget.today ?? DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(start: _period.start, end: _period.end),
      helpText: context.t('rpChooseDates'),
    );
    if (picked == null || !mounted) return;
    if (picked.end.difference(picked.start).inDays + 1 > 366) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('rpTooLong'))));
      return;
    }
    setState(() {
      _preset = ReportPreset.custom;
      _period = ReportPeriod(picked.start, picked.end);
    });
  }

  Future<void> _export(Future<void> Function() run) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await run();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.t('rpExportFailed')} $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final reports = context.watch<ReportsProvider>();
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final readable = [for (final k in reportKinds) if (access.canReadReport(k)) k];
    if (readable.isEmpty) {
      return ListView(children: [
        const SizedBox(height: FarmSpacing.lg),
        EmptyState(message: context.t('rpNoAccess'), icon: FarmIcon.report),
      ]);
    }
    final kind = readable.contains(_kind) ? _kind! : readable.first;
    final period = _period;
    final data = reports.report(kind, period);
    // Hidden in the menu's stack: nothing is fetched until it is shown.
    final visible = Visibility.of(context);
    if (visible && !_wasVisible) _fetched.clear();
    _wasVisible = visible;
    final fetchKey = '$kind:${period.key}';
    if (visible && !_fetched.contains(fetchKey) && !reports.loading(kind, period)) {
      _fetched.add(fetchKey);
      final again = data != null || reports.error(kind, period) != null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ReportsProvider>().load(kind, period, force: again);
      });
    }
    String species(String code) => livestock.speciesName(code, lang);
    final doc = data == null ? null : buildReportDoc(context, kind, data, speciesName: species);
    final blocks = doc == null ? const <GlobalKey>[] : _blocksFor(kind, _blockCount(kind, doc));
    final ready = doc != null && !_exporting;

    return ModuleWorkspace(
      header: [
        HeroBand(
          eyebrow: context.t('rpEyebrow'),
          title: context.t('navReports'),
          subtitle: context.t('rpSubtitle'),
          icon: FarmIcon.report,
          scenery: false,
          actions: [
            HeroAction(
              key: const ValueKey('report-print'),
              primary: true,
              icon: FarmIcon.report,
              label: context.t('rpPrint'),
              onPressed: ready ? () => _export(() => printReport(blocks, doc)) : null,
            ),
            HeroAction(
              key: const ValueKey('report-pdf'),
              icon: FarmIcon.download,
              label: context.t('rpDownloadPdf'),
              onPressed: ready ? () => _export(() => shareReportPdf(blocks, doc)) : null,
            ),
            HeroAction(
              key: const ValueKey('report-csv'),
              icon: FarmIcon.download,
              label: context.t('rpExportCsv'),
              onPressed: ready ? () => _export(() => saveReportCsv(doc)) : null,
            ),
          ],
        ),
        const SizedBox(height: FarmSpacing.md),
        _PeriodChips(preset: _preset, period: period, onPreset: _setPreset, onCustom: _pickRange),
      ],
      labels: [for (final k in readable) context.t(_kindLabels[k]!)],
      selected: readable.indexOf(kind),
      onSelect: (i) => setState(() => _kind = readable[i]),
      tabBuilder: (context, i) {
        final k = readable[i];
        final r = context.watch<ReportsProvider>();
        final d = r.report(k, period);
        if (d == null) {
          final error = r.error(k, period);
          if (error != null) {
            return SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                NoticeBanner(title: context.t('rpLoadFailed'), text: error),
                const SizedBox(height: FarmSpacing.md),
                OutlinedButton(
                  key: ValueKey('report-retry-$k'),
                  onPressed: () => context.read<ReportsProvider>().load(k, period, force: true),
                  child: Text(context.t('retry')),
                ),
              ]),
            );
          }
          return const Padding(padding: EdgeInsets.all(FarmSpacing.xl), child: Center(child: CircularProgressIndicator()));
        }
        final kDoc = k == kind && doc != null ? doc : buildReportDoc(context, k, d, speciesName: species);
        return ReportView(
          key: ValueKey('report-view-$k'),
          kind: k,
          data: d,
          doc: kDoc,
          blocks: _blocksFor(k, _blockCount(k, kDoc)),
          onRefresh: () => context.read<ReportsProvider>().load(k, period, force: true),
        );
      },
    );
  }

  /// The header with the figures, the milk chart, then one per table.
  static int _blockCount(String kind, ReportDoc doc) => 1 + (kind == 'milk' ? 1 : 0) + doc.tables.length;
}

class _PeriodChips extends StatelessWidget {
  const _PeriodChips({required this.preset, required this.period, required this.onPreset, required this.onCustom});

  final ReportPreset preset;
  final ReportPeriod period;
  final ValueChanged<ReportPreset> onPreset;
  final VoidCallback onCustom;

  static const _labels = {
    ReportPreset.last7: 'rpLast7',
    ReportPreset.last30: 'rpLast30',
    ReportPreset.thisMonth: 'rpThisMonth',
    ReportPreset.lastMonth: 'rpLastMonth',
  };

  @override
  Widget build(BuildContext context) {
    String d(DateTime x) => '${x.day}/${x.month}/${x.year}';
    return Wrap(
      spacing: FarmSpacing.sm,
      runSpacing: FarmSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final p in _labels.keys)
          ChoiceChip(
            key: ValueKey('report-period-${p.name}'),
            label: Text(context.t(_labels[p]!)),
            selected: preset == p,
            onSelected: (_) => onPreset(p),
          ),
        ChoiceChip(
          key: const ValueKey('report-period-custom'),
          avatar: const AppIcon(FarmIcon.calendar, size: 18),
          label: Text(preset == ReportPreset.custom ? '${d(period.start)} – ${d(period.end)}' : context.t('rpCustom')),
          selected: preset == ReportPreset.custom,
          onSelected: (_) => onCustom(),
        ),
      ],
    );
  }
}

/// One report as it is read on screen and printed: the title and period
/// with the headline figures, the milk chart, then the tables. Each part
/// is painted on its own ([blocks]) so the PDF can be cut between parts.
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.kind, required this.data, required this.doc, required this.blocks, this.onRefresh});

  final String kind;
  final Map<String, dynamic> data;
  final ReportDoc doc;
  final List<GlobalKey> blocks;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    var b = 0;
    Widget block(Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: FarmSpacing.md),
          child: RepaintBoundary(key: blocks[b++], child: ColoredBox(color: FarmColors.stone, child: child)),
        );
    final farm = (data['farm_name'] as String?) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        block(SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(doc.title, style: FarmTypography.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text([if (farm.isNotEmpty) farm, doc.period].join(' · '), style: FarmTypography.textTheme.bodySmall),
                ]),
              ),
              if (onRefresh != null)
                IconButton(
                  key: ValueKey('report-refresh-$kind'),
                  tooltip: context.t('rpRefresh'),
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ]),
            const SizedBox(height: FarmSpacing.md),
            EqualGrid(
              minTileWidth: 150,
              maxColumns: 4,
              spacing: FarmSpacing.sm,
              children: [for (final (label, value) in doc.kpis) _Figure(label: label, value: value)],
            ),
          ]),
        )),
        if (kind == 'milk') block(_MilkChart(days: [for (final d in (data['by_day'] as List<dynamic>? ?? const [])) (d as Map).cast<String, dynamic>()])),
        for (final table in doc.tables) block(SectionCard(title: table.title, child: ReportTableView(table: table))),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.md, vertical: FarmSpacing.sm),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: FarmTypography.textTheme.labelMedium?.copyWith(color: FarmColors.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(value, style: FarmTypography.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

/// Litres per day — per week or month for a long period — stacked by
/// milking session.
class _MilkChart extends StatelessWidget {
  const _MilkChart({required this.days});
  final List<Map<String, dynamic>> days;

  @override
  Widget build(BuildContext context) {
    double v(Map<String, dynamic> d, String k) => ((d[k] as num?) ?? 0).toDouble();
    final step = days.length <= 31 ? 1 : (days.length <= 120 ? 7 : 30);
    final bars = <BarGroup>[];
    for (var i = 0; i < days.length; i += step) {
      final part = days.sublist(i, (i + step).clamp(0, days.length));
      final first = DateTime.tryParse('${part.first['date']}');
      final every = days.length <= 14 ? 1 : (days.length <= 31 ? 3 : 1);
      final label = first == null || (bars.length % every != 0)
          ? ''
          : (step == 1 ? '${first.day}' : (step == 7 ? '${first.day}/${first.month}' : '${first.month}/${first.year % 100}'));
      bars.add(BarGroup(label: label, segments: [
        part.fold(0.0, (t, d) => t + v(d, 'morning')),
        part.fold(0.0, (t, d) => t + v(d, 'midday')),
        part.fold(0.0, (t, d) => t + v(d, 'evening')),
      ]));
    }
    final total = days.fold(0.0, (t, d) => t + v(d, 'total'));
    return SectionCard(
      title: context.t(step == 1 ? 'rpChartPerDay' : (step == 7 ? 'rpChartPerWeek' : 'rpChartPerMonth')),
      child: total == 0
          ? Text(context.t('rpNothingInPeriod'), style: FarmTypography.textTheme.bodySmall)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              BarTrendChart(bars: bars, segmentColors: const [FarmColors.milkBlue, FarmColors.gold, FarmColors.cedar], height: 180),
              const SizedBox(height: FarmSpacing.sm),
              Wrap(spacing: FarmSpacing.md, children: [
                _Legend(color: FarmColors.milkBlue, label: context.t('sessionMorning')),
                _Legend(color: FarmColors.gold, label: context.t('sessionMidday')),
                _Legend(color: FarmColors.cedar, label: context.t('sessionEvening')),
              ]),
            ]),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label, style: FarmTypography.textTheme.bodySmall),
      ]);
}

/// A report table: rows as tall as their text, numbers at the end of
/// their column, an empty table said in words.
class ReportTableView extends StatelessWidget {
  const ReportTableView({super.key, required this.table});
  final ReportTable table;

  @override
  Widget build(BuildContext context) {
    if (table.rows.isEmpty) {
      return Text(context.t('rpNothingInPeriod'), style: FarmTypography.textTheme.bodySmall);
    }
    final flex = table.flex ?? List.filled(table.columns.length, 1);
    Widget row(List<String> cells, {bool header = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            for (var i = 0; i < cells.length; i++)
              Expanded(
                flex: i < flex.length ? flex[i] : 1,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(end: i == cells.length - 1 ? 0 : FarmSpacing.sm),
                  child: Text(
                    cells[i],
                    textAlign: table.numeric.contains(i) ? TextAlign.end : TextAlign.start,
                    maxLines: header ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: header
                        ? FarmTypography.textTheme.labelMedium?.copyWith(color: FarmColors.muted)
                        : FarmTypography.textTheme.bodyMedium,
                  ),
                ),
              ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      row(table.columns, header: true),
      const Divider(height: 1, color: FarmColors.border),
      for (var r = 0; r < table.rows.length; r++) ...[
        row(table.rows[r]),
        if (r != table.rows.length - 1) const Divider(height: 1, color: FarmColors.border),
      ],
    ]);
  }
}
