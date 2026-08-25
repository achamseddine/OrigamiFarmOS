import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/inventory.dart';
import 'package:farmos/domain/entities/production.dart';

// Pure-Dart unit tests for the validation rules in tech spec §14 — no
// platform channels involved, so these run identically on any target.
void main() {
  group('EggRecord.isValid (tech spec §14: allocation cannot exceed total)', () {
    test('accepts an allocation that sums to exactly the total', () {
      final record = EggRecord(
        id: 'e1',
        flockId: 'flock-1',
        totalEggs: 100,
        sellableEggs: 80,
        brokenEggs: 10,
        consumed: 5,
        hatched: 3,
        wasted: 2,
        recordedAt: DateTime(2026, 5, 13),
      );
      expect(record.isValid, isTrue);
    });

    test('rejects an allocation that exceeds the total', () {
      final record = EggRecord(
        id: 'e2',
        flockId: 'flock-1',
        totalEggs: 100,
        sellableEggs: 80,
        brokenEggs: 30,
        consumed: 0,
        hatched: 0,
        wasted: 0,
        recordedAt: DateTime(2026, 5, 13),
      );
      expect(record.isValid, isFalse);
    });

    test('rejects negative components', () {
      final record = EggRecord(
        id: 'e3',
        flockId: 'flock-1',
        totalEggs: 100,
        sellableEggs: -5,
        brokenEggs: 10,
        consumed: 0,
        hatched: 0,
        wasted: 0,
        recordedAt: DateTime(2026, 5, 13),
      );
      expect(record.isValid, isFalse);
    });
  });

  group('InventoryItem stock status (tech spec §14: low-stock warnings)', () {
    InventoryItem itemWith(double qty) => InventoryItem(
          id: 'feed-1',
          name: 'Dairy Mix',
          category: 'Dairy',
          unit: 'kg',
          currentQty: qty,
          reorderLevel: 2000,
          supplier: 'Al Mashreq',
          lastPurchase: DateTime(2026, 5, 6),
        );

    test('is good when comfortably above the reorder level', () {
      expect(itemWith(3250).status, StockStatus.good);
      expect(itemWith(3250).shortfall, 0);
    });

    test('is low at or below the reorder level', () {
      expect(itemWith(1800).status, StockStatus.low);
    });

    test('is critical well below the reorder level and reports a shortfall', () {
      final item = itemWith(1000);
      expect(item.status, StockStatus.critical);
      expect(item.shortfall, 1000);
    });
  });

  group('Animal.isUnderWithdrawal (tech spec §14: milk withdrawal block)', () {
    test('true while the withdrawal date is in the future', () {
      final animal = Animal(
        id: 'goat-willow',
        tag: 'S-118',
        name: 'Willow',
        species: AnimalSpecies.goat,
        breed: 'Saanen',
        sex: 'F',
        birthDate: DateTime(2023, 1, 1),
        status: AnimalHealthStatus.underTreatment,
        location: 'Hillside Paddock',
        healthScore: 64,
        underWithdrawalUntil: DateTime.now().add(const Duration(days: 2)),
      );
      expect(animal.isUnderWithdrawal, isTrue);
    });

    test('false once the withdrawal date has passed', () {
      final animal = Animal(
        id: 'goat-willow',
        tag: 'S-118',
        name: 'Willow',
        species: AnimalSpecies.goat,
        breed: 'Saanen',
        sex: 'F',
        birthDate: DateTime(2023, 1, 1),
        status: AnimalHealthStatus.healthy,
        location: 'Hillside Paddock',
        healthScore: 90,
        underWithdrawalUntil: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(animal.isUnderWithdrawal, isFalse);
    });

    test('false when no withdrawal has ever been recorded', () {
      final animal = Animal(
        id: 'cow-214',
        tag: '214',
        name: 'Luna',
        species: AnimalSpecies.cow,
        breed: 'Holstein',
        sex: 'F',
        birthDate: DateTime(2020, 1, 1),
        status: AnimalHealthStatus.healthy,
        location: 'North Pasture',
        healthScore: 92,
      );
      expect(animal.isUnderWithdrawal, isFalse);
    });
  });
}
