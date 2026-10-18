import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app/app_navigator.dart';
import '../../domain/entities/access.dart';
import '../animals/animal_digital_twin_screen.dart';

/// Turns an `(entityType, entityId)` pair into actual navigation.
///
/// Every notification and every priority card carries that pair, which is
/// what makes them working links rather than decoration: tapping
/// "Mastitis Risk — Cow 744" opens Cow 744, tapping "Low feed: Dairy Mix"
/// opens Feed & Inventory.
///
/// An entity whose owning module the user does not hold is not silently
/// ignored — [openEntity] returns false and the caller tells them why,
/// rather than a tap that appears broken.
class EntityRouter {
  const EntityRouter._();

  /// The module that owns each entity type — used both to find the tab and
  /// to check the user may go there.
  static const Map<String, String> _moduleForEntity = {
    'animal': FarmModule.animals,
    'flock': FarmModule.eggProduction,
    'inventory_item': FarmModule.feedNutrition,
    'task': FarmModule.tasks,
    'field': FarmModule.produceHarvest,
    'harvest_record': FarmModule.produceHarvest,
    'crop_planting': FarmModule.agriculture,
    'recommendation': FarmModule.aiIntelligence,
    'mouneh_product': FarmModule.mounehInventory,
    'mouneh_batch': FarmModule.mounehProduction,
    'visit_session': FarmModule.farmVisits,
    'visit_booking': FarmModule.farmVisits,
    'sale': FarmModule.finance,
    'expense': FarmModule.finance,
    'employee': FarmModule.employees,
    // The farm pharmacy and the emergency engine live on the Health
    // screen (its Pharmacy and Emergency tabs); a stock alert, a medicine,
    // a lot, a triage, a run or a health case all open there and the
    // screen picks the tab from the entity type.
    'medicine_product': FarmModule.animalHealth,
    'pharmacy_stock_alert': FarmModule.animalHealth,
    'inventory_lot': FarmModule.animalHealth,
    'medication_administration': FarmModule.animalHealth,
    'treatment': FarmModule.animalHealth,
    'health_case': FarmModule.animalHealth,
    'emergency_assessment': FarmModule.animalHealth,
    'emergency_run': FarmModule.animalHealth,
    'emergency_protocol': FarmModule.animalHealth,
    // Numbered mixes, lots, products and the performance findings open the
    // feed workspace, which focuses the matching tab.
    'feed_batch': FarmModule.feedNutrition,
    'feed_mix': FarmModule.feedNutrition,
    'feed_lot': FarmModule.feedNutrition,
    'feed_product': FarmModule.feedNutrition,
    'feed_formula': FarmModule.feedNutrition,
    'feeding_program': FarmModule.feedNutrition,
    'feed_performance_alert': FarmModule.feedNutrition,
    'feed_performance_monitor': FarmModule.feedNutrition,
    'supplier': FarmModule.feedNutrition,
    'purchase_requisition': FarmModule.inventory,
    'farm_asset': FarmModule.settings,
    'unit_of_measure': FarmModule.settings,
    'animal_group': FarmModule.animals,
    'group': FarmModule.animals,
  };

  /// Entity types the Health screen's Pharmacy tab serves.
  static const Set<String> pharmacyEntities = {'medicine_product', 'pharmacy_stock_alert', 'inventory_lot', 'medication_administration'};

  /// Entity types the Health screen's Emergency tab serves.
  static const Set<String> emergencyEntities = {'health_case', 'emergency_assessment', 'emergency_run', 'emergency_protocol'};

  static String? moduleFor(String entityType) => _moduleForEntity[entityType];

  /// Opens the record. Returns false when there is nowhere to send the
  /// user — an unknown entity type, or a module they do not hold.
  static bool openEntity(BuildContext context, String? entityType, String? entityId) {
    if (entityType == null || entityId == null) return false;
    final navigator = context.read<AppNavigator>();

    // An animal has a screen of its own, so it opens as a full route
    // rather than a tab switch — the user comes back to where they were.
    if (entityType == 'animal') {
      if (!navigator.hasModule(FarmModule.animals) && !navigator.hasModule(FarmModule.animalHealth)) {
        return false;
      }
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: entityId)),
      );
      return true;
    }

    final module = _moduleForEntity[entityType];
    if (module == null) return false;
    return navigator.goToModule(module, entityType: entityType, entityId: entityId);
  }

  /// Opens the record, or explains why it cannot — so a tap always does
  /// something the user can understand.
  static void openEntityOrExplain(BuildContext context, String? entityType, String? entityId) {
    if (openEntity(context, entityType, entityId)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          entityType == null
              ? 'There is nothing to open for this item.'
              : "You do not have access to the screen this item belongs to. Ask a farm manager if you need it.",
        ),
      ),
    );
  }
}
