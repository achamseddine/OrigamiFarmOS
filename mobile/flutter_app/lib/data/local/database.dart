import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Local SQLite schema — a faithful subset of `database/schema.sql`
/// (the PostgreSQL source of truth) adapted to SQLite types. Every table
/// here mirrors tech spec §9 "Database Schema - MVP Tables".
///
/// IDs are TEXT (UUID strings) and timestamps are TEXT (ISO-8601) so the
/// same values round-trip cleanly to/from the FastAPI/Postgres backend.
class FarmDatabase {
  FarmDatabase._();
  static final FarmDatabase instance = FarmDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final path = p.join(docsDir.path, 'origami_farmos.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        final batch = db.batch();
        for (final stmt in _createStatements) {
          batch.execute(stmt);
        }
        await batch.commit(noResult: true);
      },
    );
  }

  static const List<String> _createStatements = [
    '''
    CREATE TABLE farms (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      region TEXT,
      country TEXT,
      timezone TEXT,
      default_currency TEXT
    );
    ''',
    '''
    CREATE TABLE locations (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      parent_id TEXT,
      name TEXT NOT NULL,
      type TEXT
    );
    ''',
    '''
    CREATE TABLE animals (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      tag TEXT NOT NULL,
      name TEXT NOT NULL,
      species TEXT NOT NULL,
      breed TEXT,
      sex TEXT,
      birth_date TEXT,
      status TEXT NOT NULL,
      location TEXT,
      health_score INTEGER,
      pregnant INTEGER DEFAULT 0,
      pregnancy_days INTEGER,
      lactating INTEGER DEFAULT 0,
      lactation_cycle INTEGER,
      withdrawal_until TEXT,
      withdrawal_reason TEXT,
      weight_kg REAL,
      group_name TEXT,
      photo_path TEXT,
      updated_at TEXT
    );
    ''',
    '''
    CREATE TABLE flocks (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      species TEXT NOT NULL,
      count INTEGER NOT NULL,
      status TEXT,
      location TEXT
    );
    ''',
    '''
    CREATE TABLE fields (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      crop_type TEXT,
      stage TEXT,
      est_yield_kg REAL,
      next_harvest TEXT
    );
    ''',
    '''
    CREATE TABLE inventory_items (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      category TEXT,
      unit TEXT NOT NULL,
      current_qty REAL NOT NULL DEFAULT 0,
      reorder_level REAL NOT NULL DEFAULT 0,
      supplier TEXT,
      unit_cost REAL,
      last_purchase TEXT
    );
    ''',
    '''
    CREATE TABLE inventory_transactions (
      id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      direction TEXT NOT NULL,
      quantity REAL NOT NULL,
      reason TEXT,
      linked_entity_type TEXT,
      linked_entity_id TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY(item_id) REFERENCES inventory_items(id)
    );
    ''',
    '''
    CREATE TABLE observations (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      observation_type TEXT NOT NULL,
      quality TEXT NOT NULL,
      value_numeric REAL,
      value_text TEXT,
      unit TEXT,
      severity TEXT,
      observer_id TEXT NOT NULL,
      observed_at TEXT NOT NULL,
      notes TEXT,
      verified INTEGER DEFAULT 0
    );
    ''',
    '''
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload_json TEXT,
      created_by TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE tasks (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      title TEXT NOT NULL,
      category TEXT,
      due_at TEXT,
      priority TEXT NOT NULL DEFAULT 'medium',
      status TEXT NOT NULL DEFAULT 'open',
      source_type TEXT,
      source_id TEXT,
      assigned_to TEXT
    );
    ''',
    '''
    CREATE TABLE recommendations (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      category TEXT NOT NULL,
      priority TEXT NOT NULL,
      title TEXT NOT NULL,
      entity_label TEXT,
      confidence REAL NOT NULL,
      rationale TEXT NOT NULL,
      suggested_action TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'generated',
      rule_id TEXT,
      generated_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE recommendation_evidence (
      id TEXT PRIMARY KEY,
      recommendation_id TEXT NOT NULL,
      label TEXT NOT NULL,
      value TEXT NOT NULL,
      FOREIGN KEY(recommendation_id) REFERENCES recommendations(id)
    );
    ''',
    '''
    CREATE TABLE milk_records (
      id TEXT PRIMARY KEY,
      animal_id TEXT NOT NULL,
      session TEXT NOT NULL,
      liters REAL NOT NULL,
      quality_status TEXT,
      destination TEXT NOT NULL,
      recorded_at TEXT NOT NULL,
      recorded_by TEXT
    );
    ''',
    '''
    CREATE TABLE egg_records (
      id TEXT PRIMARY KEY,
      flock_id TEXT NOT NULL,
      total_eggs INTEGER NOT NULL,
      sellable_eggs INTEGER NOT NULL,
      broken_eggs INTEGER NOT NULL,
      consumed INTEGER NOT NULL,
      hatched INTEGER NOT NULL,
      wasted INTEGER NOT NULL,
      recorded_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE harvest_records (
      id TEXT PRIMARY KEY,
      field_id TEXT NOT NULL,
      product_name TEXT NOT NULL,
      quantity_kg REAL NOT NULL,
      waste_kg REAL DEFAULT 0,
      destination TEXT,
      recorded_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE treatments (
      id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      diagnosis TEXT,
      medication TEXT NOT NULL,
      dose TEXT NOT NULL,
      route TEXT NOT NULL,
      start_at TEXT NOT NULL,
      end_at TEXT,
      withdrawal_until TEXT,
      responsible_user_id TEXT NOT NULL,
      status TEXT DEFAULT 'active',
      notes TEXT
    );
    ''',
    '''
    CREATE TABLE sales (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      product_type TEXT NOT NULL,
      product_label TEXT,
      quantity REAL,
      unit TEXT,
      amount REAL NOT NULL,
      currency TEXT DEFAULT 'USD',
      payment_status TEXT NOT NULL,
      customer_id TEXT,
      sold_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE expenses (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      category TEXT NOT NULL,
      amount REAL NOT NULL,
      currency TEXT DEFAULT 'USD',
      supplier_id TEXT,
      linked_entity_type TEXT,
      linked_entity_id TEXT,
      incurred_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE sync_queue (
      id TEXT PRIMARY KEY,
      local_event_id TEXT,
      operation TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      payload_json TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE audit_log (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      action TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      timestamp TEXT NOT NULL
    );
    ''',
  ];

  /// Test-only: drop and recreate every table (used by repository tests).
  Future<void> resetForTests(Database db) async {
    for (final stmt in _createStatements) {
      final name = RegExp(r'CREATE TABLE (\w+)').firstMatch(stmt)?.group(1);
      if (name != null) {
        await db.execute('DROP TABLE IF EXISTS $name');
      }
    }
    final batch = db.batch();
    for (final stmt in _createStatements) {
      batch.execute(stmt);
    }
    await batch.commit(noResult: true);
  }
}
