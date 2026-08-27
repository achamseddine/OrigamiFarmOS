import '../../domain/entities/access.dart';

/// What a queued write is *about*, in words a farmer recognises.
///
/// The sync panel has to say "3 waiting: Milk record, Animal, Task" — not
/// "POST /production/milk". The label is stored as an i18n key so the
/// panel reads the same in Arabic; the module code lets the panel group
/// by area of the farm and lets a worker see which of their
/// responsibilities is waiting to sync.
typedef OutboxDescriptor = ({String labelKey, String moduleCode});

const OutboxDescriptor _unknown = (labelKey: 'outboxChange', moduleCode: FarmModule.morningOperations);

/// Longest-prefix wins, so `/mouneh/batches/{id}/complete` is described as
/// a batch rather than falling through to the generic label.
const Map<String, OutboxDescriptor> _byPathPrefix = {
  '/tasks': (labelKey: 'outboxTask', moduleCode: FarmModule.tasks),
  '/animals': (labelKey: 'outboxAnimal', moduleCode: FarmModule.animals),
  '/observations': (labelKey: 'outboxObservation', moduleCode: FarmModule.animals),
  '/health/treatments': (labelKey: 'outboxTreatment', moduleCode: FarmModule.animalHealth),
  '/production/milk': (labelKey: 'outboxMilkRecord', moduleCode: FarmModule.milkProduction),
  '/production/eggs': (labelKey: 'outboxEggRecord', moduleCode: FarmModule.eggProduction),
  '/production/harvest': (labelKey: 'outboxHarvest', moduleCode: FarmModule.produceHarvest),
  '/harvest': (labelKey: 'outboxHarvest', moduleCode: FarmModule.produceHarvest),
  '/fields': (labelKey: 'outboxField', moduleCode: FarmModule.agriculture),
  '/crops': (labelKey: 'outboxCrop', moduleCode: FarmModule.agriculture),
  '/crop-plantings': (labelKey: 'outboxPlanting', moduleCode: FarmModule.agriculture),
  '/feed/transactions': (labelKey: 'outboxFeedMovement', moduleCode: FarmModule.feedNutrition),
  '/recommendations': (labelKey: 'outboxDecision', moduleCode: FarmModule.aiIntelligence),
  '/notifications': (labelKey: 'outboxNotificationRead', moduleCode: FarmModule.morningOperations),
  '/employees': (labelKey: 'outboxEmployee', moduleCode: FarmModule.employees),
  '/mouneh/products': (labelKey: 'outboxMounehProduct', moduleCode: FarmModule.mounehProduction),
  '/mouneh/raw-materials': (labelKey: 'outboxRawMaterial', moduleCode: FarmModule.mounehInventory),
  '/mouneh/batches': (labelKey: 'outboxMounehBatch', moduleCode: FarmModule.mounehProduction),
  '/mouneh/sales': (labelKey: 'outboxSale', moduleCode: FarmModule.sales),
  '/visit-bookings': (labelKey: 'outboxBooking', moduleCode: FarmModule.farmVisits),
  '/visit-sessions': (labelKey: 'outboxVisitSession', moduleCode: FarmModule.farmVisits),
  '/visit-calendar': (labelKey: 'outboxOpeningDay', moduleCode: FarmModule.farmVisits),
  '/visit-packages': (labelKey: 'outboxPackage', moduleCode: FarmModule.farmVisits),
  '/visit-activities': (labelKey: 'outboxActivity', moduleCode: FarmModule.farmVisits),
  '/visit-staff-roster': (labelKey: 'outboxRoster', moduleCode: FarmModule.farmVisits),
  '/visit-costs': (labelKey: 'outboxVisitCost', moduleCode: FarmModule.farmVisits),
  '/visit-retail-sales': (labelKey: 'outboxSale', moduleCode: FarmModule.sales),
  '/visit-incidents': (labelKey: 'outboxIncident', moduleCode: FarmModule.farmVisits),
  '/visitor-feedback': (labelKey: 'outboxFeedback', moduleCode: FarmModule.farmVisits),
  '/visitors': (labelKey: 'outboxVisitor', moduleCode: FarmModule.farmVisits),
  '/modules': (labelKey: 'outboxModuleLicense', moduleCode: FarmModule.settings),
};

OutboxDescriptor describeWrite(String path) {
  OutboxDescriptor? best;
  var bestLength = 0;
  for (final entry in _byPathPrefix.entries) {
    final prefix = entry.key;
    final matches = path == prefix || path.startsWith('$prefix/');
    if (matches && prefix.length > bestLength) {
      best = entry.value;
      bestLength = prefix.length;
    }
  }
  return best ?? _unknown;
}
