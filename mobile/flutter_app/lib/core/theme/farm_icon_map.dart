import 'package:flutter/material.dart';
import '../widgets/app_icon.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';

/// The one place a *thing* is turned into an icon.
///
/// From the pack's `08_flutter/icon_mapping.dart`: a central mapping
/// between semantic FarmOS actions and modules and the icon assets,
/// instead of a switch statement on every screen. Four screens used to
/// carry their own copy of "which icon is a goat", and they had already
/// started to disagree about what a turkey looks like.
///
/// Everything here resolves to a [FarmIcon], which is a pack SVG. The
/// Material fallbacks the pack lists are kept at the bottom for the few
/// widgets that take an [IconData] (the sync pill's states, a notice).
class FarmIconMap {
  FarmIconMap._();

  // --- actions ---------------------------------------------------------
  static const FarmIcon add = FarmIcon.plus;
  static const FarmIcon download = FarmIcon.download;
  static const FarmIcon search = FarmIcon.search;
  static const FarmIcon history = FarmIcon.report;
  static const FarmIcon signOut = FarmIcon.logout;
  static const FarmIcon notifications = FarmIcon.bell;
  static const FarmIcon sync = FarmIcon.cloudSync;
  static const FarmIcon language = FarmIcon.language;
  static const FarmIcon scanQr = FarmIcon.qr;

  // --- animals ---------------------------------------------------------
  /// The icon for a species, from the catalog's `icon` hint (`cow`,
  /// `poultry`, `duck`…) — or the species code itself when the catalog
  /// has not loaded. A species the pack has no drawing for gets the barn:
  /// never a crash, and never a cow standing in for a camel.
  static FarmIcon species(String hint) => switch (hint.trim().toLowerCase()) {
        'cow' || 'cows' || 'cattle' || 'bull' || 'calf' => FarmIcon.cow,
        'goat' || 'goats' || 'kid' => FarmIcon.goat,
        'sheep' || 'ewe' || 'ram' || 'lamb' => FarmIcon.sheep,
        'horse' || 'horses' || 'mare' || 'stallion' || 'foal' || 'donkey' => FarmIcon.horse,
        'duck' || 'ducks' || 'goose' || 'geese' => FarmIcon.duck,
        'poultry' || 'hen' || 'chicken' || 'layer_hen' || 'broiler' || 'turkey' || 'bird' || 'quail' => FarmIcon.poultry,
        _ => FarmIcon.barn,
      };

  static FarmIcon health(AnimalHealthStatus s) => switch (s) {
        AnimalHealthStatus.healthy => FarmIcon.heart,
        AnimalHealthStatus.underObservation => FarmIcon.eye,
        AnimalHealthStatus.underTreatment => FarmIcon.medicine,
      };

  // --- stock -----------------------------------------------------------
  static FarmIcon feedCategory(String category) => switch (category.trim().toLowerCase()) {
        'medicine' || 'medication' || 'vet' => FarmIcon.medicine,
        'minerals' || 'mineral' || 'supplement' || 'supplements' => FarmIcon.inventory,
        'produce' || 'vegetables' || 'fruit' || 'crop' => FarmIcon.harvestBasket,
        _ => FarmIcon.feedBag,
      };

  // --- modules ---------------------------------------------------------
  /// One icon per module code, for anywhere a module is named on its own:
  /// the More sheet, a permission row, a queued write's label.
  static FarmIcon module(String code) => switch (code) {
        FarmModule.morningOperations => FarmIcon.sun,
        FarmModule.animals => FarmIcon.cow,
        FarmModule.animalHealth => FarmIcon.stethoscope,
        FarmModule.feedNutrition => FarmIcon.feedBag,
        FarmModule.inventory => FarmIcon.inventory,
        FarmModule.milkProduction => FarmIcon.milkBottle,
        FarmModule.eggProduction => FarmIcon.egg,
        FarmModule.agriculture => FarmIcon.leaf,
        FarmModule.produceHarvest => FarmIcon.harvestBasket,
        FarmModule.mounehProduction || FarmModule.mounehInventory => FarmIcon.package,
        FarmModule.sales => FarmIcon.cart,
        FarmModule.expenses || FarmModule.finance => FarmIcon.coins,
        FarmModule.farmVisits => FarmIcon.calendar,
        FarmModule.employees => FarmIcon.people,
        FarmModule.tasks => FarmIcon.task,
        FarmModule.reports => FarmIcon.report,
        FarmModule.aiIntelligence => FarmIcon.chartLine,
        FarmModule.settings => FarmIcon.settings,
        _ => FarmIcon.barn,
      };

  // --- Material fallbacks (pack's icon_mapping.dart, verbatim) ---------
  //
  // For the handful of places that take an IconData rather than draw a
  // pack SVG. Prefer the SVG when exact visual parity matters.
  static const Map<String, IconData> materialFallback = {
    'bell': Icons.notifications_none_rounded,
    'cloud-sync': Icons.cloud_done_outlined,
    'cow': Icons.pets_outlined,
    'egg': Icons.egg_outlined,
    'milk-bottle': Icons.local_drink_outlined,
    'leaf': Icons.eco_outlined,
    'feed-bag': Icons.inventory_2_outlined,
    'task': Icons.task_alt_outlined,
    'warning': Icons.warning_amber_rounded,
    'settings': Icons.settings_outlined,
    'calendar': Icons.calendar_month_outlined,
    'money': Icons.paid_outlined,
    'report': Icons.description_outlined,
    'stethoscope': Icons.health_and_safety_outlined,
    'syringe': Icons.vaccines_outlined,
    'plus': Icons.add_rounded,
    'search': Icons.search_rounded,
    'download': Icons.download_rounded,
  };
}
