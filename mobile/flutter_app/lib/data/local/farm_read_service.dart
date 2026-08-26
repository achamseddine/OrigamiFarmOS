import '../../domain/entities/animal.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/entities/task.dart';
import 'database.dart';

/// Reads the device's durable SQLite projection. Data reaches these tables
/// through login/bootstrap and sync; the application never manufactures
/// sample farm records at runtime.
class FarmReadService {
  FarmReadService({FarmDatabase? database}) : _database = database ?? FarmDatabase.instance;

  final FarmDatabase _database;

  Future<List<Animal>> animals() async {
    final db = await _database.database;
    final rows = await db.query('animals', orderBy: 'name COLLATE NOCASE');
    return rows.map(_animalFromRow).toList(growable: false);
  }

  Future<List<InventoryItem>> inventoryItems() async {
    final db = await _database.database;
    final rows = await db.query('inventory_items', orderBy: 'name COLLATE NOCASE');
    return rows.map(_inventoryFromRow).toList(growable: false);
  }

  Future<List<FarmTask>> tasks() async {
    final db = await _database.database;
    final rows = await db.query('tasks', orderBy: 'due_at');
    return rows.map(_taskFromRow).toList(growable: false);
  }

  Animal _animalFromRow(Map<String, Object?> row) => Animal(
        id: row['id'] as String,
        tag: row['tag'] as String,
        name: row['name'] as String,
        species: _species(row['species'] as String),
        breed: row['breed'] as String? ?? '',
        sex: row['sex'] as String? ?? '',
        birthDate: DateTime.tryParse(row['birth_date'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        status: _healthStatus(row['status'] as String),
        location: row['location'] as String? ?? '',
        healthScore: (row['health_score'] as num?)?.toInt() ?? 0,
        photoPath: row['photo_path'] as String?,
        pregnant: (row['pregnant'] as int? ?? 0) == 1,
        pregnancyDays: (row['pregnancy_days'] as num?)?.toInt(),
        lactating: (row['lactating'] as int? ?? 0) == 1,
        lactationCycle: (row['lactation_cycle'] as num?)?.toInt(),
        underWithdrawalUntil: DateTime.tryParse(row['withdrawal_until'] as String? ?? ''),
        withdrawalReason: row['withdrawal_reason'] as String?,
        weightKg: (row['weight_kg'] as num?)?.toDouble(),
        groupName: row['group_name'] as String?,
      );

  InventoryItem _inventoryFromRow(Map<String, Object?> row) => InventoryItem(
        id: row['id'] as String,
        name: row['name'] as String,
        category: row['category'] as String? ?? '',
        unit: row['unit'] as String,
        currentQty: (row['current_qty'] as num).toDouble(),
        reorderLevel: (row['reorder_level'] as num).toDouble(),
        supplier: row['supplier'] as String? ?? '',
        lastPurchase: DateTime.tryParse(row['last_purchase'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        unitCost: (row['unit_cost'] as num?)?.toDouble(),
      );

  FarmTask _taskFromRow(Map<String, Object?> row) => FarmTask(
        id: row['id'] as String,
        title: row['title'] as String,
        category: row['category'] as String? ?? '',
        dueAt: DateTime.tryParse(row['due_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        priority: _priority(row['priority'] as String),
        status: _taskStatus(row['status'] as String),
        sourceType: row['source_type'] as String?,
        sourceId: row['source_id'] as String?,
        assignedTo: row['assigned_to'] as String?,
      );

  AnimalSpecies _species(String value) => switch (value) {
        'goat' => AnimalSpecies.goat,
        'sheep' => AnimalSpecies.sheep,
        'horse' => AnimalSpecies.horse,
        'layer_hen' => AnimalSpecies.layerHen,
        'duck' => AnimalSpecies.duck,
        'turkey' => AnimalSpecies.turkey,
        _ => AnimalSpecies.cow,
      };

  AnimalHealthStatus _healthStatus(String value) => switch (value) {
        'under_observation' => AnimalHealthStatus.underObservation,
        'under_treatment' => AnimalHealthStatus.underTreatment,
        _ => AnimalHealthStatus.healthy,
      };

  TaskPriority _priority(String value) => switch (value) {
        'high' => TaskPriority.high,
        'low' => TaskPriority.low,
        _ => TaskPriority.medium,
      };

  TaskStatus _taskStatus(String value) => switch (value) {
        'in_progress' => TaskStatus.inProgress,
        'done' => TaskStatus.done,
        _ => TaskStatus.open,
      };
}
