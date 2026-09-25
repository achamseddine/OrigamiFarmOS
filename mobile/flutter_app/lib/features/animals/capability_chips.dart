import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/livestock.dart';

/// What the farm will track for an animal, as the resolver decided it:
/// "Milk production · Pregnancy · Hoof care". Shown under the Add Animal
/// selectors so the farmer sees the consequence of the profile they
/// picked, and on the Digital Twin so a missing milk card reads as "this
/// animal is not milked" rather than as a bug.
///
/// Identification capabilities are left out — they shape the form's
/// fields rather than being something to announce — and so are the ones
/// every animal has (health, feed, mortality, weight), which would only
/// bury the ones that differ: milk, eggs, pregnancy, hoof care, wool.
class CapabilityChips extends StatelessWidget {
  const CapabilityChips({super.key, required this.caps});
  final CapabilitySet caps;

  static const _quietCategories = {'identification'};
  static const _quietCodes = {Cap.health, Cap.feed, Cap.mortality, Cap.weightTracking, Cap.bodyCondition};

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final shown = [
      for (final c in caps.capabilities)
        if (!_quietCategories.contains(c.category) && !_quietCodes.contains(c.code)) c,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in shown)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.pill)),
            child: Text(
              c.label(lang),
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: FarmColors.cedar),
            ),
          ),
      ],
    );
  }
}
