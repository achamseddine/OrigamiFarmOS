import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/reproduction.dart';

/// The livestock record behind the herd (LIVESTOCK-SCHEMA, REPRODUCTION-
/// SCHEMA): reproduction, lactation, group membership, head counts, exits
/// and the incubator.
///
/// Every write goes through [ApiClient.write], so it works the way every
/// other write on the tablet does — straight to the server when it answers,
/// otherwise into the outbox with the cached screens updated at once
/// (`cache_effects.dart`). The server decides every rule; a refusal comes
/// back as its own sentence in [WriteResult.error].
class HerdRecordsProvider extends ChangeNotifier {
  HerdRecordsProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  ReproOverview overview = const ReproOverview();
  bool loading = false;

  // ------------------------------------------------------------ reads
  Future<void> loadOverview() async {
    loading = true;
    notifyListeners();
    try {
      overview = ReproOverview.fromJson(await _api.get('/reproduction/overview') as Map<String, dynamic>);
    } on ApiException {
      overview = const ReproOverview();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<ReproTimeline> timeline(String animalId) async =>
      ReproTimeline.fromJson(await _api.get('/animals/$animalId/reproduction') as Map<String, dynamic>);

  Future<List<StateChange>> history(String animalId) async =>
      [for (final r in await _api.get('/animals/$animalId/history') as List<dynamic>) StateChange.fromJson(r as Map<String, dynamic>)];

  Future<List<GroupMembership>> members(String groupId) async =>
      [for (final r in await _api.get('/animal-groups/$groupId/members') as List<dynamic>) GroupMembership.fromJson(r as Map<String, dynamic>)];

  Future<List<QuantityEvent>> quantityEvents(String groupId) async =>
      [for (final r in await _api.get('/animal-groups/$groupId/quantity-events') as List<dynamic>) QuantityEvent.fromJson(r as Map<String, dynamic>)];

  Future<List<IncubationBatch>> incubations() async =>
      [for (final r in await _api.get('/incubations') as List<dynamic>) IncubationBatch.fromJson(r as Map<String, dynamic>)];

  // ------------------------------------------------------------ reproduction
  Future<WriteResult> recordBreeding(String animalId, {required String eventType, DateTime? occurredAt, String? maleAnimalId, String? sireReference, String? semenBatch, String? notes}) =>
      _write(() => _api.post('/animals/$animalId/breedings', body: {
            'event_type': eventType,
            if (occurredAt != null) 'occurred_at': occurredAt.toUtc().toIso8601String(),
            'male_animal_id': ?maleAnimalId,
            if (_blank(sireReference) != null) 'sire_reference': _blank(sireReference),
            if (_blank(semenBatch) != null) 'semen_batch_reference': _blank(semenBatch),
            if (_blank(notes) != null) 'notes': _blank(notes),
          }));

  Future<WriteResult> recordPregnancyCheck(String animalId, {required String assessmentType, required String resultCode, DateTime? assessedAt, int? gestationDays, String? notes}) =>
      _write(() => _api.post('/animals/$animalId/pregnancy-checks', body: {
            'assessment_type': assessmentType,
            'result_code': resultCode,
            if (assessedAt != null) 'assessed_at': assessedAt.toUtc().toIso8601String(),
            'estimated_gestation_days': ?gestationDays,
            if (_blank(notes) != null) 'notes': _blank(notes),
          }));

  Future<WriteResult> recordPregnancyLoss(String animalId, {required String outcomeCode, DateTime? occurredAt, String? notes}) =>
      _write(() => _api.post('/animals/$animalId/pregnancy-loss', body: {
            'outcome_code': outcomeCode,
            if (occurredAt != null) 'occurred_at': occurredAt.toUtc().toIso8601String(),
            if (_blank(notes) != null) 'notes': _blank(notes),
          }));

  /// [offspring] rows are the server's `NewbornIn` shape — see
  /// `reproduction_forms.dart`, which builds them.
  Future<WriteResult> recordBirth(String animalId, {required List<Map<String, dynamic>> offspring, String assistanceCode = 'NONE', DateTime? occurredAt, String? notes, bool startLactation = true}) =>
      _write(() => _api.post('/animals/$animalId/births', body: {
            'offspring': offspring,
            'assistance_code': assistanceCode,
            'start_lactation': startLactation,
            if (occurredAt != null) 'occurred_at': occurredAt.toUtc().toIso8601String(),
            if (_blank(notes) != null) 'notes': _blank(notes),
          }));

  Future<WriteResult> registerOffspring(String birthId, int sequenceNo, {required String name, required String identifierType, required String identifierValue, String? sex}) =>
      _write(() => _api.post('/births/$birthId/offspring/$sequenceNo/register', body: {
            'name': name,
            'sex': ?sex,
            'identifiers': [
              // Optional: without a tag the server gives the newborn the farm's next number.
              if (identifierValue.trim().isNotEmpty) {'identifier_type': identifierType, 'identifier_value': identifierValue.trim(), 'is_primary': true},
            ],
          }));

  /// [at] is the calving / start of milking; null means now.
  Future<WriteResult> startLactation(String animalId, {DateTime? at}) =>
      _write(() => _api.post('/animals/$animalId/lactations', body: {if (at != null) 'started_at': at.toUtc().toIso8601String()}));

  /// Corrects the calving / start-of-milking date of the current lactation.
  Future<WriteResult> correctLactationStart(String animalId, DateTime startedAt, {String? reason}) =>
      _write(() => _api.patch('/animals/$animalId/lactation', body: {
            'started_at': startedAt.toUtc().toIso8601String(),
            if (_blank(reason) != null) 'reason': _blank(reason),
          }));

  Future<WriteResult> dryOff(String animalId, {DateTime? at}) =>
      _write(() => _api.post('/animals/$animalId/dry-off', body: {if (at != null) 'ended_at': at.toUtc().toIso8601String()}));

  // ------------------------------------------------------------ lifecycle
  Future<WriteResult> exitAnimal(String animalId, {required String exitType, DateTime? occurredAt, String? reason}) =>
      _write(() => _api.post('/animals/$animalId/exit', body: {
            'exit_type': exitType,
            if (occurredAt != null) 'occurred_at': occurredAt.toUtc().toIso8601String(),
            if (_blank(reason) != null) 'reason': _blank(reason),
          }));

  // ------------------------------------------------------------ groups
  /// [groupName] travels with the request so an offline tablet can show the
  /// animal in its new group before the server confirms; the server reads
  /// only the ids.
  Future<WriteResult> addToGroup(String groupId, String animalId, {String? groupName, String? reason}) =>
      _write(() => _api.post('/animal-groups/$groupId/members', body: {
            'animal_id': animalId,
            'group_name': ?groupName,
            if (_blank(reason) != null) 'reason': _blank(reason),
          }));

  Future<WriteResult> removeFromGroup(String groupId, String animalId, {String? reason}) =>
      _write(() => _api.post('/animal-groups/$groupId/members/$animalId/end', body: {
            if (_blank(reason) != null) 'reason': _blank(reason),
          }));

  Future<WriteResult> recordQuantity(String groupId, {required String eventType, required int delta, String? reason}) =>
      _write(() => _api.post('/animal-groups/$groupId/quantity-events', body: {
            'event_type': eventType,
            'quantity_delta': delta,
            if (_blank(reason) != null) 'reason': _blank(reason),
          }));

  // ------------------------------------------------------------ incubation
  Future<WriteResult> startIncubation({required String speciesCode, required int eggsSet, String? sourceGroupId, String? notes}) =>
      _write(() => _api.post('/incubations', body: {
            'species_code': speciesCode,
            'eggs_set': eggsSet,
            'source_group_id': ?sourceGroupId,
            if (_blank(notes) != null) 'notes': _blank(notes),
          }));

  Future<WriteResult> recordHatch(String batchId, {required int hatchedLive, int? unhatched, String? destinationGroupId}) =>
      _write(() => _api.post('/incubations/$batchId/hatch', body: {
            'hatched_live': hatchedLive,
            'unhatched': ?unhatched,
            'destination_group_id': ?destinationGroupId,
          }));

  // ------------------------------------------------------------ helpers
  Future<WriteResult> _write(Future<dynamic> Function() action) async {
    final result = await _api.write(action);
    if (result.success) unawaited(loadOverview());
    return result;
  }

  static String? _blank(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
}
