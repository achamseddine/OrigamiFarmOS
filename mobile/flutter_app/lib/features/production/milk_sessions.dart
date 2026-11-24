import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../providers/milk_sales_provider.dart';

/// Whether this farm calls its second milking the afternoon one (the
/// records keep the session code "evening"; Milk page → Collector).
bool secondMilkingIsAfternoon(BuildContext context) {
  try {
    return Provider.of<MilkSalesProvider>(context, listen: false).routine.afternoon;
  } catch (_) {
    return false;
  }
}

/// "Morning", "Midday", and "Afternoon" or "Evening" as the farm says it.
String milkSessionLabel(BuildContext context, String session) => switch (session) {
      'morning' => context.t('sessionMorning'),
      'midday' => context.t('sessionMidday'),
      'evening' => context.t(secondMilkingIsAfternoon(context) ? 'sessionAfternoon' : 'sessionEvening'),
      _ => session,
    };

/// "Morning milking", and "Afternoon milking" or "Evening milking".
String milkingRoundLabel(BuildContext context, String session) => session == 'evening'
    ? context.t(secondMilkingIsAfternoon(context) ? 'routineMilkAfternoon' : 'routineMilkEvening')
    : context.t('routineMilkMorning');
