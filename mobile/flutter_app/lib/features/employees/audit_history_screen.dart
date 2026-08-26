import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/notification.dart';
import '../../providers/access_provider.dart';
import '../../providers/employees_provider.dart';
import '../navigation/entity_router.dart';

/// Audit History (tech spec §23) — who changed what, when, and from what
/// to what. Each entry links to the record it changed, so "Maya changed
/// Dairy Mix stock from 1,400 kg to 1,250 kg" opens Dairy Mix.
class AuditHistoryScreen extends StatefulWidget {
  const AuditHistoryScreen({super.key, this.entityType, this.entityId, this.title});

  final String? entityType;
  final String? entityId;
  final String? title;

  @override
  State<AuditHistoryScreen> createState() => _AuditHistoryScreenState();
}

class _AuditHistoryScreenState extends State<AuditHistoryScreen> {
  String? _moduleFilter;
  String? _userFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    await context.read<EmployeesProvider>().loadAudit(
          entityType: widget.entityType,
          entityId: widget.entityId,
          module: _moduleFilter,
          userId: _userFilter,
        );
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EmployeesProvider>();
    final access = context.watch<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final events = provider.auditEvents;
    final people = {for (final e in provider.employees) e.id: e.name};
    final modules = {for (final e in events) if (e.moduleCode != null) e.moduleCode!}.toList()..sort();

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.xl, vertical: FarmSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(context.t('back')),
                ),
                const Spacer(),
                IconButton(onPressed: _fetch, icon: const Icon(Icons.refresh), tooltip: context.t('refresh')),
              ]),
              Text(widget.title ?? context.t('auditHistory'), style: FarmTypography.display(size: 26)),
              const SizedBox(height: 2),
              Text(context.t('auditSubtitle'), style: FarmTypography.textTheme.bodyMedium),
              const SizedBox(height: FarmSpacing.md),
              if (widget.entityId == null)
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      ChoiceChip(
                        label: Text(context.t('all')),
                        selected: _moduleFilter == null && _userFilter == null,
                        onSelected: (_) {
                          setState(() {
                            _moduleFilter = null;
                            _userFilter = null;
                          });
                          _fetch();
                        },
                      ),
                      for (final code in modules) ...[
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: Text(access.moduleLabel(code, language)),
                          selected: _moduleFilter == code,
                          onSelected: (_) {
                            setState(() => _moduleFilter = _moduleFilter == code ? null : code);
                            _fetch();
                          },
                        ),
                      ],
                      for (final entry in people.entries) ...[
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: _userFilter == entry.key,
                          onSelected: (_) {
                            setState(() => _userFilter = _userFilter == entry.key ? null : entry.key);
                            _fetch();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: FarmSpacing.md),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : events.isEmpty
                        ? Center(child: Text(context.t('noAuditEntries'), style: FarmTypography.textTheme.bodyMedium))
                        : ListView.separated(
                            itemCount: events.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, i) => _AuditRow(event: events[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.event});
  final AuditEvent event;

  @override
  Widget build(BuildContext context) {
    final access = context.read<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final canOpen = EntityRouter.moduleFor(event.entityType) != null;

    return SectionCard(
      padding: const EdgeInsets.all(FarmSpacing.md),
      child: InkWell(
        onTap: canOpen ? () => EntityRouter.openEntityOrExplain(context, event.entityType, event.entityId) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  event.summary ?? '${event.userName ?? event.userId} · ${event.action.replaceAll('_', ' ')}',
                  style: FarmTypography.textTheme.titleSmall,
                ),
              ),
              Text(
                '${event.timestamp.day}/${event.timestamp.month} '
                '${TimeOfDay.fromDateTime(event.timestamp).format(context)}',
                style: const TextStyle(fontSize: 11, color: FarmColors.muted),
              ),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              StatusPill(label: event.action.replaceAll('_', ' '), level: FarmStatusLevel.info, dense: true),
              if (event.moduleCode != null)
                StatusPill(label: access.moduleLabel(event.moduleCode!, language), level: FarmStatusLevel.neutral, dense: true),
              StatusPill(label: event.entityType.replaceAll('_', ' '), level: FarmStatusLevel.neutral, dense: true),
            ]),
            if (event.changes.isNotEmpty) ...[
              const SizedBox(height: 8),
              // The actual before/after, which is the whole point of §23.
              for (final change in event.changes.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(change.key.replaceAll('_', ' '),
                            style: const TextStyle(fontSize: 11.5, color: FarmColors.muted)),
                      ),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: _render(change.value, 'from'),
                              style: const TextStyle(fontSize: 11.5, color: FarmColors.danger, decoration: TextDecoration.lineThrough),
                            ),
                            const TextSpan(text: '  →  ', style: TextStyle(fontSize: 11.5, color: FarmColors.muted)),
                            TextSpan(
                              text: _render(change.value, 'to'),
                              style: const TextStyle(fontSize: 11.5, color: FarmColors.success, fontWeight: FontWeight.w700),
                            ),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _render(dynamic change, String key) {
    if (change is! Map) return '—';
    final value = change[key];
    if (value == null) return '—';
    if (value is List) return value.isEmpty ? '—' : value.join(', ');
    return value.toString();
  }
}
