import '../../domain/entities/animal.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/entities/task.dart';
import 'database.dart';
import 'entity_mappers.dart';

/// Typed reads off the local SQLite cache — the single source every
/// provider loads its initial in-memory list from, whether those rows came
/// from `demo_seed.dart` (demo mode) or `repositories/bootstrap_repository.dart`
/// (a real farm's data pulled from the server). Providers keep writing
/// through `farm_write_service.dart` as before; this class only covers the
/// read side.
class LocalRepository {
  LocalRepository({FarmDatabase? db}) : _db = db ?? FarmDatabase.instance;
  final FarmDatabase _db;

  Future<List<Animal>> loadAnimals() async {
    final db = await _db.database;
    final rows = await db.query('animals', orderBy: 'name');
    return rows.map(animalFromRow).toList();
  }

  Future<List<InventoryItem>> loadFeedItems() async {
    final db = await _db.database;
    final rows = await db.query('inventory_items', orderBy: 'name');
    return rows.map(inventoryItemFromRow).toList();
  }

  Future<List<FarmTask>> loadTasks() async {
    final db = await _db.database;
    final rows = await db.query('tasks', orderBy: 'due_at');
    return rows.map(taskFromRow).toList();
  }
}
