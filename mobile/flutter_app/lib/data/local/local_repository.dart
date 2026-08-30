import '../../domain/entities/animal.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/entities/task.dart';
import '../remote/session_manager.dart';
import 'database.dart';
import 'entity_mappers.dart';

/// Typed reads off the local SQLite cache — the single source every
/// provider loads its initial in-memory list from, whether those rows came
/// from `demo_seed.dart` (demo mode) or `repositories/bootstrap_repository.dart`
/// (a real farm's data pulled from the server). Providers keep writing
/// through `farm_write_service.dart` as before; this class only covers the
/// read side.
///
/// **Every read here is scoped to [SessionManager.activeFarmId].** A tablet
/// is a shared device — one may be handed between farms, or a farmer may
/// sign out and another sign in — so cached rows from a previous session
/// must never surface for whoever is signed in now. That matters most
/// offline, where there's no server round trip to correct a stale list.
/// This mirrors the server's own rule (RLS + `check_farm_id`, see
/// OrigamiFarmServer `TENANCY.md`) rather than trusting the device to hold
/// only one farm's data at a time.
class LocalRepository {
  LocalRepository({required SessionManager session, FarmDatabase? db})
      : _session = session,
        _db = db ?? FarmDatabase.instance;

  final SessionManager _session;
  final FarmDatabase _db;

  Future<List<Animal>> loadAnimals() async {
    final db = await _db.database;
    final rows = await db.query(
      'animals',
      where: 'farm_id = ?',
      whereArgs: [_session.activeFarmId],
      orderBy: 'name',
    );
    return rows.map(animalFromRow).toList();
  }

  Future<List<InventoryItem>> loadFeedItems() async {
    final db = await _db.database;
    final rows = await db.query(
      'inventory_items',
      where: 'farm_id = ?',
      whereArgs: [_session.activeFarmId],
      orderBy: 'name',
    );
    return rows.map(inventoryItemFromRow).toList();
  }

  Future<List<FarmTask>> loadTasks() async {
    final db = await _db.database;
    final rows = await db.query(
      'tasks',
      where: 'farm_id = ?',
      whereArgs: [_session.activeFarmId],
      orderBy: 'due_at',
    );
    return rows.map(taskFromRow).toList();
  }

  /// Removes every locally cached row belonging to [farmId], including any
  /// still-unsynced queued writes for it.
  ///
  /// Called on sign-out and when signing in as a different farm (see
  /// `features/settings/settings_screen.dart`): scoped reads already stop
  /// one farm's data being *shown* to another, and this stops it being
  /// *retained* on the device at all once that farm is done with it.
  ///
  /// The demo farm is deliberately left alone — it's shipped sample data,
  /// not anyone's real records, and it's what the app falls back to when
  /// signed out.
  Future<void> purgeFarmData(String farmId) async {
    if (farmId == SessionManager.demoFarmId) return;
    final db = await _db.database;
    await db.transaction((txn) async {
      // Queued writes first, and only this farm's: a pending row is
      // identified by the event that produced it (sync_queue itself has no
      // farm column — see database.dart), so anything whose event is gone
      // or belongs to another farm is left untouched.
      await txn.delete(
        'sync_queue',
        where: 'local_event_id IN (SELECT id FROM events WHERE farm_id = ?)',
        whereArgs: [farmId],
      );
      for (final table in const ['events', 'animals', 'inventory_items', 'tasks', 'observations']) {
        await txn.delete(table, where: 'farm_id = ?', whereArgs: [farmId]);
      }
    });
  }
}
