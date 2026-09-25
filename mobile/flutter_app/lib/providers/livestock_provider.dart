import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/livestock.dart';
import '../livestock/capability_resolver.dart';

/// Species, breeds, profiles and the capability rules — the configuration
/// that decides what the Add Animal form asks and what an animal's
/// profile shows.
///
/// Loaded once, read synchronously. The species list and every species'
/// configuration are fetched up front: they are small, they change
/// rarely, and having them cached is what lets the form resolve
/// capabilities on the device with no signal.
class LivestockProvider extends ChangeNotifier {
  LivestockProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  List<Species> _species = [];
  List<CapabilityDef> _catalog = [];
  final Map<String, SpeciesConfiguration> _configurations = {};
  List<AnimalGroup> _groups = [];
  bool loading = false;
  String? error;

  List<Species> get species => List.unmodifiable(_species);
  List<CapabilityDef> get catalog => List.unmodifiable(_catalog);
  List<AnimalGroup> get groups => List.unmodifiable(_groups);
  bool get isLoaded => _species.isNotEmpty;

  Species? speciesByCode(String code) {
    for (final s in _species) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// The species name in the current language, or the code made readable
  /// if the catalog has not loaded — never a crash on an unknown code.
  String speciesName(String code, String languageCode) =>
      speciesByCode(code)?.name(languageCode) ?? code.replaceAll('_', ' ');

  /// The icon-map hint for a species code. Falls back to the code itself,
  /// which the icon map also understands for the species it has drawings
  /// of — so a cow is still a cow before the catalog has loaded.
  String speciesIcon(String code) => speciesByCode(code)?.icon ?? code;

  /// "Calving" / "Lambing" / "Foaling" for a species code.
  String term(String speciesCode, String key, String languageCode, {String fallback = ''}) =>
      speciesByCode(speciesCode)?.term(key, languageCode, fallback: fallback) ?? fallback;

  SpeciesConfiguration? configurationFor(String code) => _configurations[code];

  /// The label for a life-stage code of a species (`adult` → "Adult" /
  /// "بالغ"), or the code made readable if it is not in the catalog.
  String lifeStageLabel(String speciesCode, String? code, String languageCode) {
    if (code == null || code.isEmpty) return '';
    for (final s in _configurations[speciesCode]?.lifeStages ?? const <LifeStage>[]) {
      if (s.code == code) return s.label(languageCode);
    }
    return code.replaceAll('_', ' ');
  }

  /// The label for a management-profile code (`dairy` → "Dairy" / "حليب").
  String profileLabel(String speciesCode, String? code, String languageCode) {
    if (code == null || code.isEmpty) return '';
    for (final p in _configurations[speciesCode]?.managementProfiles ?? const <ManagementProfile>[]) {
      if (p.code == code) return p.label(languageCode);
    }
    return code.replaceAll('_', ' ');
  }

  List<Species> get oviparousSpecies => _species.where((s) => s.isOviparous).toList();

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([_api.get('/species'), _api.get('/capabilities')]);
      _species = [for (final s in results[0] as List<dynamic>) Species.fromJson(s as Map<String, dynamic>)]
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      _catalog = [for (final c in results[1] as List<dynamic>) CapabilityDef.fromJson(c as Map<String, dynamic>)];

      // Each species' configuration, tolerating a single failure — one
      // broken species must not take the form down for the rest.
      final configs = await Future.wait([
        for (final s in _species)
          _api.get('/species/${s.code}/configuration').then<SpeciesConfiguration?>(
            (json) => SpeciesConfiguration.fromJson(json as Map<String, dynamic>),
            onError: (_) => null,
          ),
      ]);
      for (final config in configs) {
        if (config != null) _configurations[config.species.code] = config;
      }
      try {
        _groups = [for (final g in await _api.get('/animal-groups') as List<dynamic>) AnimalGroup.fromJson(g as Map<String, dynamic>)];
      } on ApiException {
        _groups = [];
      }
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Resolves on the device from the cached rules. Returns
  /// [CapabilitySet.empty] until the species' configuration is known, so
  /// a form can build against it without null checks.
  CapabilitySet resolve({required String species, String? sex, String? lifeStage, String? managementProfile}) {
    final config = _configurations[species];
    if (config == null) return CapabilitySet.empty;
    return CapabilityResolver.resolve(
      configuration: config,
      catalog: _catalog,
      sex: sex,
      lifeStage: lifeStage,
      managementProfile: managementProfile,
    );
  }

  Future<WriteResult> createGroup(Map<String, dynamic> body) async {
    final result = await _api.write(() => _api.post('/animal-groups', body: body));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> addIdentifier(String animalId, AnimalIdentifier identifier) =>
      _api.write(() => _api.post('/animals/$animalId/identifiers', body: identifier.toJson()));

  Future<WriteResult> retireIdentifier(String animalId, String identifierId) =>
      _api.write(() => _api.delete('/animals/$animalId/identifiers/$identifierId'));
}
