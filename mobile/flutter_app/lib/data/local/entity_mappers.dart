import '../../domain/entities/animal.dart';
import '../../domain/entities/finance.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/entities/task.dart';

/// Best-effort conversions between three shapes of the same entity:
/// server JSON (OrigamiFarmServer's FarmOS contract — see
/// ../../../../../OrigamiFarmServer/docs/FARMOS_API.md), this app's own
/// domain entities (lib/domain/entities/), and SQLite rows
/// (data/local/database.dart, a "faithful subset of database/schema.sql").
///
/// Enum-valued fields (species, status, priority, ...) are matched
/// case/separator-insensitively rather than by exact string equality: the
/// server's field *names* are a verified contract, but this codebase has
/// no confirmed reference for its enum *value* spelling (camelCase vs
/// snake_case) for every field, so a value this app doesn't recognize
/// falls back to a safe default instead of crashing the cache/UI.
String normalizeEnumToken(String value) =>
    value.toLowerCase().replaceAll(RegExp('[_\\-\\s]'), '');

T matchEnum<T>(Iterable<T> values, String Function(T) name, String? raw, T fallback) {
  if (raw == null) return fallback;
  final normalizedRaw = normalizeEnumToken(raw);
  for (final v in values) {
    if (normalizeEnumToken(name(v)) == normalizedRaw) return v;
  }
  return fallback;
}

DateTime? parseDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse('$value');
}

double? parseDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse('$value');
}

int? parseInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

bool parseBool(Object? value) => value == true || value == 1 || value == '1';

// --------------------------------------------------------------- Animal

AnimalSpecies _species(String? raw) => matchEnum(
      AnimalSpecies.values,
      (s) => s.name,
      raw,
      AnimalSpecies.cow,
    );

AnimalHealthStatus _healthStatus(String? raw) {
  // A couple of likely server spellings beyond the exact enum name.
  const aliases = {'under_observation': 'underObservation', 'under_treatment': 'underTreatment'};
  final resolved = aliases[raw] ?? raw;
  return matchEnum(AnimalHealthStatus.values, (s) => s.name, resolved, AnimalHealthStatus.healthy);
}

/// Builds an [Animal] from a decoded `AnimalOut`/`AnimalDetailOut` JSON
/// body (`GET`/`POST /animals`).
Animal animalFromJson(Map<String, dynamic> json) => Animal(
      id: json['id'] as String,
      tag: json['tag'] as String? ?? '',
      name: json['name'] as String? ?? '',
      species: _species(json['species'] as String?),
      breed: json['breed'] as String? ?? '',
      sex: json['sex'] as String? ?? '',
      birthDate: parseDate(json['birth_date']) ?? DateTime.now(),
      status: _healthStatus(json['status'] as String?),
      location: json['location_label'] as String? ?? '',
      healthScore: parseInt(json['health_score']) ?? 100,
      photoPath: json['photo_path'] as String?,
      pregnant: parseBool(json['pregnant']),
      pregnancyDays: parseInt(json['pregnancy_days']),
      lactating: parseBool(json['lactating']),
      lactationCycle: parseInt(json['lactation_cycle']),
      underWithdrawalUntil: parseDate(json['withdrawal_until']),
      withdrawalReason: json['withdrawal_reason'] as String?,
      weightKg: parseDouble(json['weight_kg']),
      groupName: json['group_name'] as String?,
    );

/// Builds an [Animal] from a `animals` SQLite row (see database.dart).
Animal animalFromRow(Map<String, Object?> row) => Animal(
      id: row['id'] as String,
      tag: row['tag'] as String? ?? '',
      name: row['name'] as String? ?? '',
      species: _species(row['species'] as String?),
      breed: row['breed'] as String? ?? '',
      sex: row['sex'] as String? ?? '',
      birthDate: parseDate(row['birth_date']) ?? DateTime.now(),
      status: _healthStatus(row['status'] as String?),
      location: row['location'] as String? ?? '',
      healthScore: parseInt(row['health_score']) ?? 100,
      photoPath: row['photo_path'] as String?,
      pregnant: parseBool(row['pregnant']),
      pregnancyDays: parseInt(row['pregnancy_days']),
      lactating: parseBool(row['lactating']),
      lactationCycle: parseInt(row['lactation_cycle']),
      underWithdrawalUntil: parseDate(row['withdrawal_until']),
      withdrawalReason: row['withdrawal_reason'] as String?,
      weightKg: parseDouble(row['weight_kg']),
      groupName: row['group_name'] as String?,
    );

/// A local cache row for an animal fetched from the server — same shape
/// `data/local/demo_seed.dart` writes, so both sources land in one table.
Map<String, Object?> animalToRow(Map<String, dynamic> json, {required String farmId}) => {
      'id': json['id'],
      'farm_id': farmId,
      'tag': json['tag'],
      'name': json['name'],
      'species': json['species'],
      'breed': json['breed'],
      'sex': json['sex'],
      'birth_date': json['birth_date'],
      'status': json['status'],
      'location': json['location_label'],
      'health_score': json['health_score'],
      'pregnant': parseBool(json['pregnant']) ? 1 : 0,
      'pregnancy_days': json['pregnancy_days'],
      'lactating': parseBool(json['lactating']) ? 1 : 0,
      'lactation_cycle': json['lactation_cycle'],
      'withdrawal_until': json['withdrawal_until'],
      'withdrawal_reason': json['withdrawal_reason'],
      'weight_kg': json['weight_kg'],
      'group_name': json['group_name'],
      'photo_path': json['photo_path'],
      'updated_at': DateTime.now().toIso8601String(),
    };

// ----------------------------------------------------------- InventoryItem

InventoryItem inventoryItemFromJson(Map<String, dynamic> json) => InventoryItem(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '',
      unit: json['unit'] as String? ?? '',
      currentQty: parseDouble(json['current_qty']) ?? 0,
      reorderLevel: parseDouble(json['reorder_level']) ?? 0,
      supplier: json['supplier_label'] as String? ?? '',
      lastPurchase: parseDate(json['last_purchase']) ?? DateTime.now(),
      unitCost: parseDouble(json['unit_cost']),
    );

InventoryItem inventoryItemFromRow(Map<String, Object?> row) => InventoryItem(
      id: row['id'] as String,
      name: row['name'] as String? ?? '',
      category: row['category'] as String? ?? '',
      unit: row['unit'] as String? ?? '',
      currentQty: parseDouble(row['current_qty']) ?? 0,
      reorderLevel: parseDouble(row['reorder_level']) ?? 0,
      supplier: row['supplier'] as String? ?? '',
      lastPurchase: parseDate(row['last_purchase']) ?? DateTime.now(),
      unitCost: parseDouble(row['unit_cost']),
    );

Map<String, Object?> inventoryItemToRow(Map<String, dynamic> json, {required String farmId}) => {
      'id': json['id'],
      'farm_id': farmId,
      'name': json['name'],
      'category': json['category'],
      'unit': json['unit'],
      'current_qty': json['current_qty'],
      'reorder_level': json['reorder_level'],
      'supplier': json['supplier_label'],
      'unit_cost': json['unit_cost'],
      'last_purchase': json['last_purchase'],
    };

// ----------------------------------------------------------------- FarmTask

TaskPriority _taskPriority(String? raw) =>
    matchEnum(TaskPriority.values, (s) => s.name, raw, TaskPriority.medium);

TaskStatus _taskStatus(String? raw) {
  const aliases = {'in_progress': 'inProgress', 'completed': 'done', 'closed': 'done'};
  final resolved = aliases[raw] ?? raw;
  return matchEnum(TaskStatus.values, (s) => s.name, resolved, TaskStatus.open);
}

FarmTask taskFromJson(Map<String, dynamic> json) => FarmTask(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      category: (json['description'] as String?) ?? '',
      dueAt: parseDate(json['due_at']) ?? DateTime.now(),
      priority: _taskPriority(json['priority'] as String?),
      status: _taskStatus(json['status'] as String?),
      sourceType: json['source_type'] as String?,
      sourceId: json['source_id'] as String?,
      assignedTo: json['assigned_to'] as String?,
    );

FarmTask taskFromRow(Map<String, Object?> row) => FarmTask(
      id: row['id'] as String,
      title: row['title'] as String? ?? '',
      category: row['category'] as String? ?? '',
      dueAt: parseDate(row['due_at']) ?? DateTime.now(),
      priority: _taskPriority(row['priority'] as String?),
      status: _taskStatus(row['status'] as String?),
      sourceType: row['source_type'] as String?,
      sourceId: row['source_id'] as String?,
      assignedTo: row['assigned_to'] as String?,
    );

/// The server's `TaskOut` has no `category` field (this app's own local
/// addition, shown as a subtitle) — cached rows leave it blank rather than
/// guessing one.
Map<String, Object?> taskToRow(Map<String, dynamic> json, {required String farmId}) => {
      'id': json['id'],
      'farm_id': farmId,
      'title': json['title'],
      'category': null,
      'due_at': json['due_at'],
      'priority': json['priority'],
      'status': json['status'],
      'source_type': json['source_type'],
      'source_id': json['source_id'],
      'assigned_to': json['assigned_to'],
    };

// -------------------------------------------------------------- Sale/Expense

PaymentStatus _paymentStatus(String? raw) =>
    matchEnum(PaymentStatus.values, (s) => s.name, raw, PaymentStatus.paid);

/// Builds a [Sale] from a decoded `SaleOut` JSON body (`GET`/`POST /sales`).
Sale saleFromJson(Map<String, dynamic> json) => Sale(
      id: json['id'] as String,
      productType: json['product_type'] as String? ?? '',
      productLabel: json['product_label'] as String? ?? json['product_type'] as String? ?? '',
      quantity: parseDouble(json['quantity']) ?? 0,
      unit: json['unit'] as String? ?? '',
      amountUsd: parseDouble(json['amount']) ?? 0,
      paymentStatus: _paymentStatus(json['payment_status'] as String?),
      soldAt: parseDate(json['sold_at']) ?? DateTime.now(),
      customerId: json['customer_id'] as String?,
    );

/// Builds an [Expense] from a decoded `ExpenseOut` JSON body
/// (`GET`/`POST /expenses`).
Expense expenseFromJson(Map<String, dynamic> json) => Expense(
      id: json['id'] as String,
      category: json['category'] as String? ?? '',
      amountUsd: parseDouble(json['amount']) ?? 0,
      incurredAt: parseDate(json['incurred_at']) ?? DateTime.now(),
      supplierId: json['supplier_id'] as String?,
      linkedEntityType: json['linked_entity_type'] as String?,
      linkedEntityId: json['linked_entity_id'] as String?,
    );

// ---------------------------------------------------------- Recommendation

RecommendationCategory _recommendationCategory(String? raw) =>
    matchEnum(RecommendationCategory.values, (c) => c.name, raw, RecommendationCategory.health);

RecommendationPriority _recommendationPriority(String? raw) =>
    matchEnum(RecommendationPriority.values, (p) => p.name, raw, RecommendationPriority.medium);

RecommendationStatus _recommendationStatus(String? raw) =>
    matchEnum(RecommendationStatus.values, (s) => s.name, raw, RecommendationStatus.generated);

/// Builds a [Recommendation] from a decoded `RecommendationOut` JSON body
/// (`GET /recommendations`). The server's `EvidenceItem` has no
/// `trendDown` field (a purely cosmetic arrow this app's own demo data
/// adds) — real evidence just renders without one.
Recommendation recommendationFromJson(Map<String, dynamic> json) => Recommendation(
      id: json['id'] as String,
      category: _recommendationCategory(json['category'] as String?),
      priority: _recommendationPriority(json['priority'] as String?),
      title: json['title'] as String? ?? '',
      entityLabel: json['entity_label'] as String? ?? '',
      confidence: parseDouble(json['confidence']) ?? 0,
      rationale: json['rationale'] as String? ?? '',
      suggestedAction: json['suggested_action'] as String? ?? '',
      evidence: ((json['evidence'] as List<dynamic>?) ?? const [])
          .map((e) => RecommendationEvidence(
                label: (e as Map<String, dynamic>)['label'] as String? ?? '',
                value: e['value'] as String? ?? '',
              ))
          .toList(),
      generatedAt: parseDate(json['generated_at']) ?? DateTime.now(),
      status: _recommendationStatus(json['status'] as String?),
      ruleId: json['rule_id'] as String?,
    );
