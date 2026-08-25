import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/alert_card.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/bekaa_backdrop.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/top_bar.dart';
import '../../data/demo/demo_data.dart';
import '../../domain/entities/recommendation.dart';

/// Screen 1 — Welcome / Start My Day (tech spec §7 & §8: greeting,
/// practical subline, Start My Day / View Demo Farm, Bekaa Valley imagery,
/// no recurring marketing slogan).
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: FarmSpacing.xl, vertical: 8),
              child: Align(alignment: Alignment.centerRight, child: TopBar()),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(FarmSpacing.xl, 0, FarmSpacing.xl, FarmSpacing.xl),
                child: LayoutBuilder(builder: (context, constraints) {
                  final stacked = constraints.maxWidth < kTabletBreakpoint;
                  final left = _LeftPane(onStart: onStart);
                  final right = const _BriefingPreviewCard();
                  if (stacked) {
                    return SingleChildScrollView(
                      child: Column(children: [SizedBox(height: 420, child: left), const SizedBox(height: FarmSpacing.lg), right]),
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 5, child: left),
                      const SizedBox(width: FarmSpacing.xl),
                      Expanded(flex: 6, child: right),
                    ],
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftPane extends StatelessWidget {
  const _LeftPane({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: FarmRadii.panel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const BekaaBackdrop(),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [FarmColors.stone.withOpacity(0.96), FarmColors.stone.withOpacity(0.15)],
                stops: const [0.0, 0.62],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(FarmSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SvgPicture.asset('assets/logo/origami-farmos-mark.svg', width: 40, height: 40),
                        const SizedBox(width: 10),
                        RichText(
                          text: TextSpan(
                            style: FarmTypography.textTheme.titleLarge,
                            children: const [
                              TextSpan(text: 'Origami ', style: TextStyle(color: FarmColors.cedar)),
                              TextSpan(text: 'FarmOS', style: TextStyle(color: FarmColors.olive)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: FarmSpacing.xl),
                    Row(
                      children: [
                        const AppIcon(FarmIcon.sun, size: 26, color: FarmColors.gold),
                        const SizedBox(width: 10),
                        Text('${context.t('goodMorning')}, ${DemoData.managerName}',
                            style: FarmTypography.display(size: 30)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(context.t('welcomeSubline'), style: FarmTypography.textTheme.bodyLarge),
                    const SizedBox(height: FarmSpacing.lg),
                    SizedBox(
                      width: 300,
                      child: ElevatedButton.icon(
                        onPressed: onStart,
                        icon: const Icon(Icons.wb_sunny_outlined, size: 18),
                        label: Text(context.t('startMyDay')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 300,
                      child: OutlinedButton.icon(
                        onPressed: onStart,
                        icon: const AppIcon(FarmIcon.barn, size: 18),
                        label: Text(context.t('viewDemoFarm')),
                      ),
                    ),
                  ],
                ),
                _BottomStatStrip(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomStatStrip extends StatelessWidget {
  const _BottomStatStrip();

  @override
  Widget build(BuildContext context) {
    final kpis = DemoData.animalSummary;
    final items = <(FarmIcon, String, String)>[
      (FarmIcon.cow, '${kpis['total']}', context.t('kpiAnimals')),
      (FarmIcon.milkBottle, '592 ${context.t('liters')}', context.t('kpiMilkToday')),
      (FarmIcon.egg, '312', context.t('kpiEggsToday')),
      (FarmIcon.leaf, '6', context.t('kpiActiveCrops')),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: FarmColors.card.withOpacity(0.9),
        borderRadius: BorderRadius.circular(FarmRadii.md),
        border: Border.all(color: FarmColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final item in items)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(item.$1, size: 18, color: FarmColors.cedar),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(item.$2, style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                        Text(item.$3, style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BriefingPreviewCard extends StatelessWidget {
  const _BriefingPreviewCard();

  @override
  Widget build(BuildContext context) {
    final priorities = [
      for (final r in DemoData.recommendations.take(4)) r,
    ];
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.lg),
      decoration: BoxDecoration(
        color: FarmColors.card,
        borderRadius: FarmRadii.panel,
        border: Border.all(color: FarmColors.border),
        boxShadow: FarmShadows.elevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(context.t('todaysPriorities'), style: FarmTypography.textTheme.titleLarge),
              ),
              const Icon(Icons.open_in_full, size: 16, color: FarmColors.cedar2),
              const SizedBox(width: 4),
              const Text('Expand', style: TextStyle(color: FarmColors.cedar2, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          Expanded(
            child: ListView.separated(
              itemCount: priorities.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final rec = priorities[i];
                return AlertCard(
                  icon: _iconFor(rec.category),
                  title: rec.title,
                  level: _levelFor(rec.priority),
                  eyebrow: _eyebrow(context, rec.category),
                  evidence: [rec.entityLabel],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  FarmIcon _iconFor(RecommendationCategory c) {
    switch (c) {
      case RecommendationCategory.health:
        return FarmIcon.heart;
      case RecommendationCategory.feed:
        return FarmIcon.feedBag;
      case RecommendationCategory.egg:
        return FarmIcon.egg;
      case RecommendationCategory.withdrawal:
        return FarmIcon.warning;
      case RecommendationCategory.harvest:
        return FarmIcon.leaf;
      case RecommendationCategory.finance:
        return FarmIcon.money;
    }
  }

  String _eyebrow(BuildContext context, RecommendationCategory c) {
    switch (c) {
      case RecommendationCategory.health:
        return 'ANIMAL ALERT';
      case RecommendationCategory.feed:
        return 'FEED WARNING';
      case RecommendationCategory.egg:
        return 'EGG PRODUCTION';
      case RecommendationCategory.withdrawal:
        return 'WITHDRAWAL';
      case RecommendationCategory.harvest:
        return 'HARVEST REMINDER';
      case RecommendationCategory.finance:
        return 'BUSINESS INSIGHT';
    }
  }

  FarmStatusLevel _levelFor(RecommendationPriority p) {
    switch (p) {
      case RecommendationPriority.high:
        return FarmStatusLevel.alert;
      case RecommendationPriority.medium:
        return FarmStatusLevel.watch;
      case RecommendationPriority.low:
      case RecommendationPriority.info:
        return FarmStatusLevel.good;
    }
  }
}
