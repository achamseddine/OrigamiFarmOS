import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/entity_mappers.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/finance.dart';
import 'package:farmos/domain/entities/inventory.dart';
import 'package:farmos/domain/entities/recommendation.dart';
import 'package:farmos/domain/entities/task.dart';

// Pure-Dart unit tests for the server-JSON <-> domain-entity <-> SQLite-row
// conversions in lib/data/local/entity_mappers.dart. No platform channels,
// no HTTP, no database — just checking the mapping logic itself, since
// there's no live OrigamiFarmServer in this environment to integration-test
// against.
void main() {
  group('matchEnum (case/separator-insensitive enum matching)', () {
    test('matches an exact name', () {
      expect(
        matchEnum(AnimalHealthStatus.values, (s) => s.name, 'healthy', AnimalHealthStatus.healthy),
        AnimalHealthStatus.healthy,
      );
    });

    test('matches regardless of snake_case vs camelCase', () {
      expect(
        matchEnum(
          AnimalHealthStatus.values,
          (s) => s.name,
          'under_treatment',
          AnimalHealthStatus.healthy,
        ),
        AnimalHealthStatus.underTreatment,
      );
      expect(
        matchEnum(AnimalHealthStatus.values, (s) => s.name, 'UNDER-OBSERVATION', AnimalHealthStatus.healthy),
        AnimalHealthStatus.underObservation,
      );
    });

    test('falls back instead of throwing on an unrecognized value', () {
      expect(
        matchEnum(AnimalHealthStatus.values, (s) => s.name, 'quarantined', AnimalHealthStatus.healthy),
        AnimalHealthStatus.healthy,
      );
    });

    test('falls back on null', () {
      expect(
        matchEnum(AnimalHealthStatus.values, (s) => s.name, null, AnimalHealthStatus.healthy),
        AnimalHealthStatus.healthy,
      );
    });
  });

  group('animalFromJson (AnimalOut)', () {
    test('maps every field the app displays, including the location_label rename', () {
      final futureWithdrawal = DateTime.now().add(const Duration(days: 7));
      final animal = animalFromJson({
        'id': 'a1',
        'tag': '744',
        'name': 'Bella',
        'species': 'cow',
        'breed': 'Holstein',
        'sex': 'F',
        'birth_date': '2022-01-15T00:00:00Z',
        'status': 'under_treatment',
        'location_label': 'North Pasture',
        'health_score': 87,
        'pregnant': true,
        'pregnancy_days': 120,
        'lactating': true,
        'lactation_cycle': 2,
        'withdrawal_until': futureWithdrawal.toIso8601String(),
        'withdrawal_reason': 'Medication',
        'weight_kg': 612.0,
        'group_name': 'Dairy Herd',
        'photo_path': null,
      });

      expect(animal.id, 'a1');
      expect(animal.tag, '744');
      expect(animal.species, AnimalSpecies.cow);
      expect(animal.status, AnimalHealthStatus.underTreatment);
      expect(animal.location, 'North Pasture');
      expect(animal.healthScore, 87);
      expect(animal.pregnant, isTrue);
      expect(animal.lactating, isTrue);
      expect(animal.weightKg, 612.0);
      expect(animal.isUnderWithdrawal, isTrue);
    });

    test('a round trip through animalToRow -> animalFromRow preserves the cached fields', () {
      final json = {
        'id': 'a2',
        'tag': 'G-032',
        'name': 'Mira',
        'species': 'goat',
        'breed': 'Damascus',
        'sex': 'F',
        'birth_date': '2023-01-01T00:00:00Z',
        'status': 'healthy',
        'location_label': 'Hillside Paddock',
        'health_score': 76,
        'pregnant': false,
        'pregnancy_days': null,
        'lactating': false,
        'lactation_cycle': null,
        'withdrawal_until': null,
        'withdrawal_reason': null,
        'weight_kg': null,
        'group_name': 'Goat Group B',
        'photo_path': null,
      };
      final row = animalToRow(json, farmId: 'farm-1');
      expect(row['farm_id'], 'farm-1');
      expect(row['location'], 'Hillside Paddock');
      expect(row['pregnant'], 0);

      final animal = animalFromRow(row);
      expect(animal.id, 'a2');
      expect(animal.name, 'Mira');
      expect(animal.species, AnimalSpecies.goat);
      expect(animal.location, 'Hillside Paddock');
      expect(animal.pregnant, isFalse);
    });
  });

  group('inventoryItemFromJson (InventoryItemOut)', () {
    test('maps supplier_label to supplier', () {
      final item = inventoryItemFromJson({
        'id': 'i1',
        'name': 'Dairy Mix',
        'category': 'Dairy',
        'unit': 'kg',
        'current_qty': 3250.0,
        'reorder_level': 2000.0,
        'supplier_label': 'Al Mashreq',
        'unit_cost': 0.42,
        'last_purchase': '2026-05-10T00:00:00Z',
      });
      expect(item.name, 'Dairy Mix');
      expect(item.supplier, 'Al Mashreq');
      expect(item.currentQty, 3250.0);
      expect(item.status, StockStatus.good);
    });
  });

  group('taskFromJson (TaskOut)', () {
    test('maps description into category and normalizes status aliases', () {
      final task = taskFromJson({
        'id': 't1',
        'title': 'Inspect Cow 744',
        'description': 'Health check',
        'assigned_to': null,
        'due_at': '2026-05-13T09:00:00Z',
        'priority': 'high',
        'status': 'in_progress',
        'source_type': 'recommendation',
        'source_id': 'rec-1',
      });
      expect(task.title, 'Inspect Cow 744');
      expect(task.category, 'Health check');
      expect(task.priority, TaskPriority.high);
      expect(task.status, TaskStatus.inProgress);
    });

    test('taskToRow drops the server-unknown category rather than guessing one', () {
      final row = taskToRow({
        'id': 't2',
        'title': 'Reorder dairy mix',
        'due_at': null,
        'priority': 'medium',
        'status': 'open',
        'source_type': null,
        'source_id': null,
        'assigned_to': null,
      }, farmId: 'farm-1');
      expect(row['category'], isNull);
      expect(row['farm_id'], 'farm-1');
    });
  });

  group('saleFromJson / expenseFromJson', () {
    test('maps amount to amountUsd and payment_status to the enum', () {
      final sale = saleFromJson({
        'id': 's1',
        'customer_id': null,
        'product_type': 'milk',
        'product_label': 'Milk',
        'quantity': 340.0,
        'unit': 'L',
        'amount': 4250.0,
        'currency': 'USD',
        'payment_status': 'partial',
        'sold_at': '2026-05-13T09:00:00Z',
      });
      expect(sale.amountUsd, 4250.0);
      expect(sale.paymentStatus, PaymentStatus.partial);
      expect(sale.productLabel, 'Milk');
    });

    test('falls back to product_type when product_label is absent', () {
      final sale = saleFromJson({
        'id': 's2',
        'product_type': 'eggs',
        'amount': 100.0,
        'sold_at': '2026-05-13T09:00:00Z',
      });
      expect(sale.productLabel, 'eggs');
    });

    test('maps an expense', () {
      final expense = expenseFromJson({
        'id': 'e1',
        'supplier_id': null,
        'category': 'feed',
        'amount': 1680.0,
        'currency': 'USD',
        'linked_entity_type': null,
        'linked_entity_id': null,
        'incurred_at': '2026-05-13T08:00:00Z',
      });
      expect(expense.category, 'feed');
      expect(expense.amountUsd, 1680.0);
    });
  });

  group('recommendationFromJson (RecommendationOut)', () {
    test('maps evidence without a trendDown (the server has no such field)', () {
      final rec = recommendationFromJson({
        'id': 'r1',
        'farm_id': 'farm-1',
        'category': 'feed',
        'priority': 'medium',
        'title': 'Low feed: Dairy Mix',
        'entity_type': 'inventory_item',
        'entity_id': 'i1',
        'entity_label': 'Dairy Mix',
        'confidence': 0.95,
        'rationale': 'Stock has fallen to or below its reorder level.',
        'suggested_action': 'Place a reorder soon.',
        'status': 'generated',
        'rule_id': 'RULE-LOW-FEED',
        'generated_at': '2026-05-13T06:00:00Z',
        'evidence': [
          {'label': 'Current stock', 'value': '1800 kg'},
          {'label': 'Reorder level', 'value': '2000 kg'},
        ],
      });
      expect(rec.category, RecommendationCategory.feed);
      expect(rec.priority, RecommendationPriority.medium);
      expect(rec.status, RecommendationStatus.generated);
      expect(rec.evidence, hasLength(2));
      expect(rec.evidence.first.label, 'Current stock');
      expect(rec.evidence.first.trendDown, isNull);
      expect(rec.confidencePct, 95);
    });

    test('tolerates a missing evidence list', () {
      final rec = recommendationFromJson({
        'id': 'r2',
        'category': 'harvest',
        'priority': 'low',
        'title': 'Basil ready in 0 day(s)',
        'entity_label': 'Herb Garden — Basil',
        'confidence': 0.9,
        'rationale': 'Expected harvest within 48 hours.',
        'suggested_action': 'Schedule the harvest crew.',
        'status': 'generated',
        'generated_at': '2026-05-13T06:00:00Z',
      });
      expect(rec.evidence, isEmpty);
      expect(rec.category, RecommendationCategory.harvest);
    });
  });
}
