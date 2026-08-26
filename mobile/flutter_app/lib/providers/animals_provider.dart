import 'package:flutter/foundation.dart';
import '../data/local/farm_write_service.dart';
import '../data/local/farm_read_service.dart';
import '../domain/entities/animal.dart';
import '../sync/sync_queue_controller.dart';

/// Animal digital twins (Constitution: "Every object has one digital
/// twin"). Quick actions (Observe / Milk) write through [FarmWriteService]
/// to SQLite + the event log + the sync queue, then update this in-memory
/// projection so every screen reflects the change immediately — the same
/// "save locally, update UI, sync later" flow described in tech spec §10.
class AnimalsProvider extends ChangeNotifier {
  AnimalsProvider({required FarmWriteService writeService, required FarmReadService readService, required SyncQueueController syncQueue})
      : _writeService = writeService,
        _readService = readService,
        _syncQueue = syncQueue,
        _animals = [];

  final FarmWriteService _writeService;
  final FarmReadService _readService;
  final SyncQueueController _syncQueue;
  List<Animal> _animals;

  List<Animal> get animals => List.unmodifiable(_animals);

  Animal? byId(String id) {
    for (final animal in _animals) {
      if (animal.id == id) return animal;
    }
    return null;
  }

  Future<void> load() async {
    _animals = await _readService.animals();
    notifyListeners();
  }

  Future<WriteResult> recordObservation({
    required String animalId,
    required String observationType,
    required String quality,
    String? severity,
    String? notes,
    required String observerId,
  }) async {
    final result = await _writeService.recordObservation(
      entityType: 'animal',
      entityId: animalId,
      observationType: observationType,
      quality: quality,
      observerId: observerId,
      severity: severity,
      notes: notes,
    );
    if (result.success) {
      _syncQueue.enqueue(entityType: 'animal', entityId: animalId, operation: 'create');
    }
    return result;
  }

  Future<WriteResult> recordMilk({
    required String animalId,
    required String session,
    required double liters,
    required String destination,
  }) async {
    final animal = byId(animalId);
    if (animal == null) return const WriteResult.fail('Unknown animal.');
    final result = await _writeService.recordMilk(
      animalId: animalId,
      session: session,
      liters: liters,
      destination: destination,
      isUnderWithdrawal: animal.isUnderWithdrawal,
    );
    if (result.success) {
      final index = _animals.indexWhere((a) => a.id == animalId);
      if (index != -1) {
        final current = _animals[index];
        _animals[index] = Animal(
          id: current.id,
          tag: current.tag,
          name: current.name,
          species: current.species,
          breed: current.breed,
          sex: current.sex,
          birthDate: current.birthDate,
          status: current.status,
          location: current.location,
          healthScore: current.healthScore,
          photoPath: current.photoPath,
          pregnant: current.pregnant,
          pregnancyDays: current.pregnancyDays,
          lactating: current.lactating,
          lactationCycle: current.lactationCycle,
          underWithdrawalUntil: current.underWithdrawalUntil,
          withdrawalReason: current.withdrawalReason,
          milkTodayL: (current.milkTodayL ?? 0) + liters,
          eggsToday: current.eggsToday,
          weightKg: current.weightKg,
          groupName: current.groupName,
        );
      }
      notifyListeners();
      _syncQueue.enqueue(entityType: 'animal', entityId: animalId, operation: 'create');
    }
    return result;
  }

  Future<WriteResult> recordTreatment({
    required String animalId,
    required String medication,
    required String dose,
    required String route,
    String? diagnosis,
    DateTime? withdrawalUntil,
    String? notes,
    required String responsibleUserId,
  }) async {
    final result = await _writeService.recordTreatment(
      entityType: 'animal',
      entityId: animalId,
      medication: medication,
      dose: dose,
      route: route,
      responsibleUserId: responsibleUserId,
      diagnosis: diagnosis,
      withdrawalUntil: withdrawalUntil,
      notes: notes,
    );
    if (result.success) {
      _replace(animalId, (a) => _withStatus(a, status: AnimalHealthStatus.underTreatment, withdrawalUntil: withdrawalUntil));
      _syncQueue.enqueue(entityType: 'animal', entityId: animalId, operation: 'update');
    }
    return result;
  }

  Future<WriteResult> moveAnimal({required String animalId, required String newLocation}) async {
    final result = await _writeService.moveAnimal(animalId: animalId, newLocation: newLocation);
    if (result.success) {
      _replace(animalId, (a) => _withLocation(a, newLocation));
      _syncQueue.enqueue(entityType: 'animal', entityId: animalId, operation: 'update');
    }
    return result;
  }

  void _replace(String animalId, Animal Function(Animal) transform) {
    final index = _animals.indexWhere((a) => a.id == animalId);
    if (index == -1) return;
    _animals[index] = transform(_animals[index]);
    notifyListeners();
  }

  Animal _withStatus(Animal a, {required AnimalHealthStatus status, DateTime? withdrawalUntil}) => Animal(
        id: a.id,
        tag: a.tag,
        name: a.name,
        species: a.species,
        breed: a.breed,
        sex: a.sex,
        birthDate: a.birthDate,
        status: status,
        location: a.location,
        healthScore: a.healthScore,
        photoPath: a.photoPath,
        pregnant: a.pregnant,
        pregnancyDays: a.pregnancyDays,
        lactating: a.lactating,
        lactationCycle: a.lactationCycle,
        underWithdrawalUntil: withdrawalUntil ?? a.underWithdrawalUntil,
        withdrawalReason: withdrawalUntil != null ? 'Medication' : a.withdrawalReason,
        milkTodayL: a.milkTodayL,
        eggsToday: a.eggsToday,
        weightKg: a.weightKg,
        groupName: a.groupName,
      );

  Animal _withLocation(Animal a, String newLocation) => Animal(
        id: a.id,
        tag: a.tag,
        name: a.name,
        species: a.species,
        breed: a.breed,
        sex: a.sex,
        birthDate: a.birthDate,
        status: a.status,
        location: newLocation,
        healthScore: a.healthScore,
        photoPath: a.photoPath,
        pregnant: a.pregnant,
        pregnancyDays: a.pregnancyDays,
        lactating: a.lactating,
        lactationCycle: a.lactationCycle,
        underWithdrawalUntil: a.underWithdrawalUntil,
        withdrawalReason: a.withdrawalReason,
        milkTodayL: a.milkTodayL,
        eggsToday: a.eggsToday,
        weightKg: a.weightKg,
        groupName: a.groupName,
      );
}
