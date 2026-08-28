import 'package:sqflite/sqflite.dart';
import '../local/database.dart';
import '../local/entity_mappers.dart';
import '../remote/api_exception.dart';
import '../remote/farmos_api.dart';
import '../remote/session_manager.dart';

class BootstrapResult {
  const BootstrapResult.ok() : offline = false, error = null;
  const BootstrapResult.offline() : offline = true, error = null;
  const BootstrapResult.failed(String message) : offline = false, error = message;
  final bool offline;
  final String? error;
  bool get success => !offline && error == null;
}

/// Pulls this farm's current state from the server into SQLite so the app
/// can read it offline afterwards — the read half of "sqlite for demo
/// purposes and offline mode": real data, cached locally, survives a lost
/// connection exactly like the demo seed always has.
///
/// Runs once right after login (see `features/settings/settings_screen.dart`)
/// and again on demand (pull-to-refresh, reconnect) — every call replaces
/// the cached rows for signed-in farm's animals/feed items/tasks with
/// whatever the server currently has, the same "server is the source of
/// truth once online" rule `sync_engine.dart` follows for writes.
class BootstrapRepository {
  BootstrapRepository({required SessionManager session, required FarmosApi api, FarmDatabase? db})
      : _session = session,
        _api = api,
        _db = db ?? FarmDatabase.instance;

  final SessionManager _session;
  final FarmosApi _api;
  final FarmDatabase _db;

  Future<BootstrapResult> run() async {
    final farmId = _session.farmId;
    if (!_session.isLoggedIn || farmId == null) return const BootstrapResult.offline();

    try {
      final animals = await _api.listAnimals(farmId);
      final items = await _api.listFeedItems(farmId);
      final tasks = await _api.listTasks(farmId);
      final db = await _db.database;

      await db.transaction((txn) async {
        for (final a in animals) {
          await txn.insert(
            'animals',
            animalToRow(a as Map<String, dynamic>, farmId: farmId),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final i in items) {
          await txn.insert(
            'inventory_items',
            inventoryItemToRow(i as Map<String, dynamic>, farmId: farmId),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final t in tasks) {
          await txn.insert(
            'tasks',
            taskToRow(t as Map<String, dynamic>, farmId: farmId),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
      return const BootstrapResult.ok();
    } on ApiOfflineException {
      return const BootstrapResult.offline();
    } on ApiException catch (e) {
      return BootstrapResult.failed(e.detail);
    }
  }
}
