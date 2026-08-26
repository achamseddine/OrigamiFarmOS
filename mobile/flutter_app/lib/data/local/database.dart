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
    // ------------------------------------------------------------------
    // Mouneh & Farm Product Processing module (tech spec v0.5 §3). Mirrors
    // the entity names in database/schema.sql's Mouneh section exactly.
    // ------------------------------------------------------------------
    '''
    CREATE TABLE module_licenses (
      module_code TEXT PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'inactive',
      plan TEXT,
      activated_by TEXT
    );
    ''',
    '''
    CREATE TABLE raw_materials (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT 'raw_material',
      source_type TEXT NOT NULL DEFAULT 'purchased',
      unit TEXT NOT NULL,
      default_unit_cost REAL NOT NULL DEFAULT 0,
      current_stock REAL NOT NULL DEFAULT 0,
      loss_percent_default REAL NOT NULL DEFAULT 0
    );
    ''',
    '''
    CREATE TABLE mouneh_products (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT 'general',
      output_unit TEXT NOT NULL,
      custom_output_unit_label TEXT,
      default_batch_size REAL NOT NULL DEFAULT 1,
      shelf_life_days INTEGER,
      warehouse_rules TEXT,
      low_stock_threshold REAL,
      target_price REAL,
      wholesale_price REAL,
      target_margin_pct REAL,
      status TEXT NOT NULL DEFAULT 'draft',
      created_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE mouneh_recipes (
      id TEXT PRIMARY KEY,
      product_id TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 1,
      basis_quantity REAL NOT NULL,
      basis_unit TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1,
      notes TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY(product_id) REFERENCES mouneh_products(id)
    );
    ''',
    '''
    CREATE TABLE mouneh_recipe_items (
      id TEXT PRIMARY KEY,
      recipe_id TEXT NOT NULL,
      material_id TEXT NOT NULL,
      material_type TEXT NOT NULL DEFAULT 'raw_material',
      quantity REAL NOT NULL,
      unit TEXT NOT NULL,
      loss_percent REAL NOT NULL DEFAULT 0,
      FOREIGN KEY(recipe_id) REFERENCES mouneh_recipes(id)
    );
    ''',
    '''
    CREATE TABLE cost_components (
      id TEXT PRIMARY KEY,
      product_id TEXT,
      batch_id TEXT,
      cost_type TEXT NOT NULL,
      label TEXT,
      calculation_method TEXT NOT NULL DEFAULT 'fixed',
      amount REAL,
      quantity REAL,
      unit_cost REAL
    );
    ''',
    '''
    CREATE TABLE production_batches (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      recipe_id TEXT NOT NULL,
      batch_code TEXT NOT NULL,
      planned_qty REAL NOT NULL,
      actual_output_qty REAL,
      waste_qty REAL NOT NULL DEFAULT 0,
      damaged_qty REAL NOT NULL DEFAULT 0,
      quality_status TEXT NOT NULL DEFAULT 'good',
      expiry_date TEXT,
      warehouse_location TEXT,
      status TEXT NOT NULL DEFAULT 'in_progress',
      planned_unit_cost REAL,
      planned_total_cost REAL,
      actual_unit_cost REAL,
      actual_total_cost REAL,
      labor_hours REAL,
      started_at TEXT NOT NULL,
      completed_at TEXT,
      FOREIGN KEY(product_id) REFERENCES mouneh_products(id),
      FOREIGN KEY(recipe_id) REFERENCES mouneh_recipes(id)
    );
    ''',
    '''
    CREATE TABLE batch_input_consumptions (
      id TEXT PRIMARY KEY,
      batch_id TEXT NOT NULL,
      material_id TEXT NOT NULL,
      planned_qty REAL NOT NULL,
      actual_qty REAL,
      unit_cost REAL NOT NULL,
      total_cost REAL,
      FOREIGN KEY(batch_id) REFERENCES production_batches(id)
    );
    ''',
    '''
    CREATE TABLE finished_goods_stock (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      batch_id TEXT NOT NULL,
      warehouse_location TEXT,
      quantity_produced REAL NOT NULL DEFAULT 0,
      quantity_available REAL NOT NULL DEFAULT 0,
      quantity_reserved REAL NOT NULL DEFAULT 0,
      quantity_sold REAL NOT NULL DEFAULT 0,
      quantity_expired REAL NOT NULL DEFAULT 0,
      quantity_damaged REAL NOT NULL DEFAULT 0,
      unit_cost REAL NOT NULL DEFAULT 0,
      expiry_date TEXT,
      FOREIGN KEY(product_id) REFERENCES mouneh_products(id),
      FOREIGN KEY(batch_id) REFERENCES production_batches(id)
    );
    ''',
    '''
    CREATE TABLE mouneh_sale_lines (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      batch_id TEXT NOT NULL,
      finished_goods_stock_id TEXT NOT NULL,
      quantity REAL NOT NULL,
      unit_price REAL NOT NULL,
      discount REAL NOT NULL DEFAULT 0,
      channel TEXT NOT NULL DEFAULT 'retail',
      cost_per_unit REAL NOT NULL,
      revenue REAL NOT NULL,
      margin REAL NOT NULL,
      sold_at TEXT NOT NULL,
      FOREIGN KEY(product_id) REFERENCES mouneh_products(id),
      FOREIGN KEY(finished_goods_stock_id) REFERENCES finished_goods_stock(id)
    );
    ''',
    // ------------------------------------------------------------------
    // Farm Visits & Agri-Tourism module (tech spec v0.6 §4). Mirrors the
    // entity names in database/schema.sql's Visits section exactly.
    // ------------------------------------------------------------------
    '''
    CREATE TABLE visit_opening_calendar (
      weekday INTEGER PRIMARY KEY,
      is_open INTEGER NOT NULL DEFAULT 0,
      open_time TEXT,
      close_time TEXT,
      default_capacity INTEGER NOT NULL DEFAULT 0,
      notes TEXT
    );
    ''',
    '''
    CREATE TABLE visit_sessions (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      date TEXT NOT NULL,
      start_time TEXT NOT NULL,
      end_time TEXT NOT NULL,
      capacity INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'open',
      weather_note TEXT,
      expected_staff_cost REAL
    );
    ''',
    '''
    CREATE TABLE visit_packages (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      base_price REAL NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'USD',
      duration_minutes INTEGER,
      active INTEGER NOT NULL DEFAULT 1
    );
    ''',
    '''
    CREATE TABLE visit_activities (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      name TEXT NOT NULL,
      activity_type TEXT NOT NULL DEFAULT 'other',
      price REAL NOT NULL DEFAULT 0,
      capacity_per_slot INTEGER NOT NULL DEFAULT 1,
      duration_minutes INTEGER,
      requires_staff_role TEXT,
      requires_animal_id TEXT,
      max_uses_per_day INTEGER,
      active INTEGER NOT NULL DEFAULT 1
    );
    ''',
    '''
    CREATE TABLE visitor_profiles (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      full_name TEXT NOT NULL,
      phone TEXT,
      email TEXT,
      preferred_language TEXT NOT NULL DEFAULT 'en',
      notes TEXT,
      consent_marketing INTEGER NOT NULL DEFAULT 0
    );
    ''',
    '''
    CREATE TABLE visit_bookings (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      visitor_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      package_id TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft',
      adults INTEGER NOT NULL DEFAULT 1,
      children INTEGER NOT NULL DEFAULT 0,
      total_amount REAL NOT NULL DEFAULT 0,
      deposit_amount REAL NOT NULL DEFAULT 0,
      balance_due REAL NOT NULL DEFAULT 0,
      source TEXT NOT NULL DEFAULT 'manual',
      notes TEXT,
      idempotency_key TEXT,
      created_at TEXT NOT NULL,
      confirmed_at TEXT,
      checked_in_at TEXT,
      completed_at TEXT,
      cancelled_at TEXT,
      FOREIGN KEY(visitor_id) REFERENCES visitor_profiles(id),
      FOREIGN KEY(session_id) REFERENCES visit_sessions(id),
      FOREIGN KEY(package_id) REFERENCES visit_packages(id)
    );
    ''',
    '''
    CREATE TABLE visit_booking_activities (
      id TEXT PRIMARY KEY,
      booking_id TEXT NOT NULL,
      activity_id TEXT NOT NULL,
      scheduled_at TEXT NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 1,
      unit_price REAL NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'scheduled',
      FOREIGN KEY(booking_id) REFERENCES visit_bookings(id),
      FOREIGN KEY(activity_id) REFERENCES visit_activities(id)
    );
    ''',
    '''
    CREATE TABLE visit_staff_roster (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      worker_id TEXT NOT NULL,
      worker_name TEXT,
      role TEXT NOT NULL,
      start_time TEXT NOT NULL,
      end_time TEXT NOT NULL,
      hourly_rate REAL NOT NULL DEFAULT 0,
      total_cost REAL
    );
    ''',
    '''
    CREATE TABLE visit_costs (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      category TEXT NOT NULL,
      description TEXT,
      amount REAL NOT NULL DEFAULT 0,
      allocation_method TEXT NOT NULL DEFAULT 'per_session'
    );
    ''',
    '''
    CREATE TABLE visit_retail_sales (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      booking_id TEXT,
      visitor_id TEXT,
      channel TEXT NOT NULL DEFAULT 'farm_shop',
      total_amount REAL NOT NULL DEFAULT 0,
      sold_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE visitor_feedback (
      id TEXT PRIMARY KEY,
      booking_id TEXT NOT NULL,
      rating INTEGER NOT NULL,
      comments TEXT,
      would_return INTEGER,
      submitted_at TEXT NOT NULL
    );
    ''',
    '''
    CREATE TABLE visit_incidents (
      id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      booking_id TEXT,
      incident_type TEXT NOT NULL,
      severity TEXT NOT NULL DEFAULT 'low',
      description TEXT NOT NULL,
      action_taken TEXT,
      created_at TEXT NOT NULL
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
