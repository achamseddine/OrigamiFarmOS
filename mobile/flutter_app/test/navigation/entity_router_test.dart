import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/access.dart';
import 'package:farmos/features/navigation/entity_router.dart';

/// Every entity a notification, a priority card or an alert can name has
/// a screen: the pharmacy and emergency records land on the Health
/// screen's tabs, the feed records on the feed workspace, a requisition
/// on Inventory. An unknown type stays unknown rather than guessing.
void main() {
  test('pharmacy and emergency records open the Health screen', () {
    for (final type in ['medicine_product', 'pharmacy_stock_alert', 'inventory_lot', 'medication_administration', 'treatment', 'health_case', 'emergency_assessment', 'emergency_run', 'emergency_protocol']) {
      expect(EntityRouter.moduleFor(type), FarmModule.animalHealth, reason: type);
    }
    expect(EntityRouter.pharmacyEntities, containsAll(['medicine_product', 'pharmacy_stock_alert']));
    expect(EntityRouter.emergencyEntities, containsAll(['emergency_assessment', 'emergency_run', 'health_case']));
    expect(EntityRouter.pharmacyEntities.intersection(EntityRouter.emergencyEntities), isEmpty);
  });

  test('numbered mixes, lots, products and performance findings open the feed workspace', () {
    for (final type in ['feed_batch', 'feed_mix', 'feed_lot', 'feed_product', 'feed_formula', 'feeding_program', 'feed_performance_alert', 'feed_performance_monitor', 'supplier']) {
      expect(EntityRouter.moduleFor(type), FarmModule.feedNutrition, reason: type);
    }
  });

  test('a requisition opens Inventory; assets and units open Settings; groups open Animals', () {
    expect(EntityRouter.moduleFor('purchase_requisition'), FarmModule.inventory);
    expect(EntityRouter.moduleFor('farm_asset'), FarmModule.settings);
    expect(EntityRouter.moduleFor('unit_of_measure'), FarmModule.settings);
    expect(EntityRouter.moduleFor('animal_group'), FarmModule.animals);
  });

  test('the earlier routes still hold and an unknown type has no module', () {
    expect(EntityRouter.moduleFor('animal'), FarmModule.animals);
    expect(EntityRouter.moduleFor('task'), FarmModule.tasks);
    expect(EntityRouter.moduleFor('mouneh_batch'), FarmModule.mounehProduction);
    expect(EntityRouter.moduleFor('spaceship'), isNull);
  });
}
