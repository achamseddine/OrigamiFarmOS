import 'package:sqflite/sqflite.dart';
import '../../domain/entities/animal.dart';
import '../demo/demo_data.dart';
import 'database.dart';

/// Loads the Option C demo dataset into SQLite on first launch (tech spec
/// milestone M4: "SQLite schema, repositories, seed data — screens read
/// from local data"). Idempotent: skips silently if `animals` is already
/// populated so re-running on every app start is safe.
class DemoSeed {
  static Future<void> ensureSeeded() async {
    final db = await FarmDatabase.instance.database;
    final existing = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM animals')) ?? 0;
    if (existing > 0) return;

    final batch = db.batch();

    batch.insert('farms', {
      'id': DemoData.farm.id,
      'name': DemoData.farm.name,
      'region': DemoData.farm.region,
      'country': DemoData.farm.country,
      'timezone': DemoData.farm.timezone,
      'default_currency': DemoData.farm.defaultCurrency,
    });

    for (final a in DemoData.animals) {
      batch.insert('animals', {
        'id': a.id,
        'farm_id': DemoData.farm.id,
        'tag': a.tag,
        'name': a.name,
        'species': a.species.name,
        'breed': a.breed,
        'sex': a.sex,
        'birth_date': a.birthDate.toIso8601String(),
        'status': a.status.name,
        'location': a.location,
        'health_score': a.healthScore,
        'pregnant': a.pregnant ? 1 : 0,
        'pregnancy_days': a.pregnancyDays,
        'lactating': a.lactating ? 1 : 0,
        'lactation_cycle': a.lactationCycle,
        'withdrawal_until': a.underWithdrawalUntil?.toIso8601String(),
        'withdrawal_reason': a.withdrawalReason,
        'weight_kg': a.weightKg,
        'group_name': a.groupName,
        'photo_path': a.photoPath,
        'updated_at': DateTime.now().toIso8601String(),
      });
    }

    for (final item in DemoData.feedInventory) {
      batch.insert('inventory_items', {
        'id': item.id,
        'farm_id': DemoData.farm.id,
        'name': item.name,
        'category': item.category,
        'unit': item.unit,
        'current_qty': item.currentQty,
        'reorder_level': item.reorderLevel,
        'supplier': item.supplier,
        'unit_cost': item.unitCost,
        'last_purchase': item.lastPurchase.toIso8601String(),
      });
    }

    for (final t in DemoData.todaysTasks) {
      batch.insert('tasks', {
        'id': t.id,
        'farm_id': DemoData.farm.id,
        'title': t.title,
        'category': t.category,
        'due_at': t.dueAt.toIso8601String(),
        'priority': t.priority.name,
        'status': t.status.name,
        'source_type': t.sourceType,
        'source_id': t.sourceId,
        'assigned_to': t.assignedTo,
      });
    }

    await batch.commit(noResult: true);
  }

  /// Reads current animal health status back from SQLite (used by screens
  /// that have been wired to local data — see `providers/animals_provider.dart`).
  static Future<List<Map<String, Object?>>> loadAnimals() async {
    final db = await FarmDatabase.instance.database;
    return db.query('animals', orderBy: 'name');
  }
}
