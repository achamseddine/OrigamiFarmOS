import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/animal.dart';
import '../domain/entities/production_records.dart';

/// Animal digital twins (Constitution: "Every object has one digital
/// twin"). Always-online: [load] fetches the farm's animals from the
/// backend, and every quick action posts straight to the corresponding
/// endpoint, then updates this in-memory projection from the response so
/// every screen reflects the change immediately.
class AnimalsProvider extends ChangeNotifier {
  AnimalsProvider({required ApiClient apiClient, required String farmId, required String currentUserId})
      : _api = apiClient,
        _farmId = farmId,
        _currentUserId = currentUserId;

  final ApiClient _api;
  final String _farmId;
  final String _currentUserId;
  List<Animal> _animals = [];
  List<TreatmentRecord> _treatments = [];
  bool loading = false;

  List<Animal> get animals => List.unmodifiable(_animals);
  List<TreatmentRecord> get treatments => List.unmodifiable(_treatments);

  Animal byId(String id) => _animals.firstWhere((a) => a.id == id, orElse: () => _animals.first);

  List<TreatmentRecord> treatmentsFor(String entityId) => _treatments.where((t) => t.entityId == entityId).toList();

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/animals', query: {'farm_id': _farmId}),
        _api.get('/health/treatments', query: {'farm_id': _farmId}),
      ]);
      final animalsJson = results[0] as List<dynamic>;
      final treatmentsJson = results[1] as List<dynamic>;
      _animals = animalsJson.map((e) => Animal.fromJson(e as Map<String, dynamic>)).toList();
      _treatments = treatmentsJson.map((e) => TreatmentRecord.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Full digital-twin fetch for one animal (backend `AnimalDigitalTwinOut`
  /// — see api/v1/animals.py::get_animal): the usual [AnimalOut] fields
  /// plus raw-dict `recent_observations`/`recent_events`/
  /// `open_recommendations` lists, scoped server-side to this animal.
  Future<Map<String, dynamic>> fetchDigitalTwin(String animalId) async => await _api.get('/animals/$animalId') as Map<String, dynamic>;

  Future<WriteResult> recordObservation({
    required String animalId,
    required String observationType,
    required String quality,
    String? severity,
    String? notes,
    String? observerId,
  }) {
    return _api.write(() => _api.post('/observations', body: {
          'farm_id': _farmId,
          'entity_type': 'animal',
          'entity_id': animalId,
          'observation_type': observationType,
          'quality': quality,
          'severity': severity,
          'notes': notes,
          'observer_id': observerId ?? _currentUserId,
        }));
  }

  Future<WriteResult> recordMilk({
    required String animalId,
    required String session,
    required double liters,
    required String destination,
  }) async {
    final result = await _api.write(() => _api.post('/production/milk', body: {
          'animal_id': animalId,
          'session': session,
          'liters': liters,
          'destination': destination,
        }));
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
        notifyListeners();
      }
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
    String? responsibleUserId,
  }) async {
    final result = await _api.write(() => _api.post('/health/treatments', body: {
          'entity_type': 'animal',
          'entity_id': animalId,
          'medication': medication,
          'dose': dose,
          'route': route,
          'responsible_user_id': responsibleUserId ?? _currentUserId,
          'diagnosis': diagnosis,
          'withdrawal_until': withdrawalUntil?.toIso8601String(),
          'notes': notes,
        }));
    if (result.success) {
      _replace(animalId, (a) => _withStatus(a, status: AnimalHealthStatus.underTreatment, withdrawalUntil: withdrawalUntil));
    }
    return result;
  }

  Future<WriteResult> moveAnimal({required String animalId, required String newLocation}) async {
    final result = await _api.write(() => _api.patch('/animals/$animalId', body: {'location_label': newLocation}));
    if (result.success) {
      _replace(animalId, (a) => _withLocation(a, newLocation));
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
