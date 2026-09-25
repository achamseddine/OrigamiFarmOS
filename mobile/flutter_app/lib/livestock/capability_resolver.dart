import '../domain/entities/livestock.dart';

/// The capability resolver, on the device.
///
/// A Dart port of `backend/app/services/capability_service.py::resolve`,
/// over the same rule rows the server uses (`GET /species/{code}/
/// configuration`). The Add Animal form calls this as the farmer picks
/// species → sex → stage → profile, so the fields and switches it shows
/// are exactly what the server will accept — and it works in a field
/// with no signal, because the rules are cached with the rest of the
/// farm. Kept behaviour-identical on purpose; the mirrored tests in
/// `test/livestock_resolver_test.dart` are the same cases as the Python
/// ones.
///
/// Resolution is configuration first, biology last:
///
/// 1. Every rule whose sex / stage / profile match or are unset is a
///    candidate. Per capability, the most *specific* granting rule wins
///    (priority breaks ties); any matching rule that disables it is a
///    veto and wins outright.
/// 2. Then the invariants: a male is never pregnant, lactating or laying;
///    an oviparous species never has a pregnancy line; a viviparous one
///    never lays. These are not configurable.
class CapabilityResolver {
  const CapabilityResolver._();

  static const _neverForMales = {Cap.pregnancy, Cap.liveBirth, Cap.lactation, Cap.milkProduction, Cap.eggProduction};
  static const _neverForOviparous = {Cap.pregnancy, Cap.liveBirth, Cap.lactation, Cap.milkProduction};
  static const _neverForViviparous = {Cap.eggProduction, Cap.incubation, Cap.hatching};

  static CapabilitySet resolve({
    required SpeciesConfiguration configuration,
    required List<CapabilityDef> catalog,
    String? sex,
    String? lifeStage,
    String? managementProfile,
  }) {
    final species = configuration.species;
    final stage = (lifeStage == null || lifeStage.isEmpty) ? kDefaultLifeStage : lifeStage;
    final sexCode = _normaliseSex(sex);
    final defs = {for (final d in catalog) d.code: d};

    // Most specific grant per capability; any disable is a veto.
    final grants = <String, (int, int, CapabilityRule)>{};
    final vetoed = <String>{};
    for (final rule in configuration.rules) {
      if (rule.sex != null && rule.sex!.toUpperCase() != sexCode) continue;
      if (rule.lifeStage != null && rule.lifeStage != stage) continue;
      if (rule.managementProfile != null && rule.managementProfile != managementProfile) continue;
      if (!rule.enabled) {
        vetoed.add(rule.capabilityCode);
        continue;
      }
      final key = (rule.specificity, rule.priority);
      final current = grants[rule.capabilityCode];
      if (current == null || _better(key, (current.$1, current.$2))) {
        grants[rule.capabilityCode] = (rule.specificity, rule.priority, rule);
      }
    }
    final enabled = <String, CapabilityRule>{
      for (final e in grants.entries)
        if (defs.containsKey(e.key) && !vetoed.contains(e.key)) e.key: e.value.$3,
    };

    // Invariants — after configuration, so a misconfigured rule can never
    // override biology. `suppressed` lists everything biology rules out
    // for this animal, granted or not.
    final forbidden = <String>{};
    if (sexCode == Sex.male) forbidden.addAll(_neverForMales);
    if (species.isOviparous) forbidden.addAll(_neverForOviparous);
    if (species.isViviparous) forbidden.addAll(_neverForViviparous);
    final suppressed = (forbidden.where(defs.containsKey).toList()..sort());
    for (final code in suppressed) {
      enabled.remove(code);
    }

    final order = {for (var i = 0; i < catalog.length; i++) catalog[i].code: i};
    final codes = enabled.keys.toList()..sort((a, b) => (order[a] ?? 999).compareTo(order[b] ?? 999));
    final capabilities = [
      for (final code in codes)
        ResolvedCapability(
          code: code,
          category: defs[code]!.category,
          labelEn: defs[code]!.labelEn,
          labelAr: defs[code]!.labelAr,
          required: enabled[code]!.required,
          configuration: enabled[code]!.configuration,
        ),
    ];
    final codeSet = codes.toSet();

    final allowed = {...IdentifierType.alwaysAllowed};
    final requiredTypes = <String>{};
    for (final e in IdentifierType.forCapability.entries) {
      if (codeSet.contains(e.key)) {
        allowed.add(e.value);
        if (enabled[e.key]!.required) requiredTypes.add(e.value);
      }
    }

    final individual = codeSet.contains(Cap.individualTracking);
    final group = codeSet.contains(Cap.groupTracking);

    return CapabilitySet(
      species: species.code,
      sex: sexCode,
      lifeStage: stage,
      managementProfile: managementProfile,
      reproductionMode: species.reproductionMode,
      subjectKind: individual && group ? 'either' : (group ? 'group' : 'individual'),
      capabilities: capabilities,
      allowedIdentifierTypes: allowed.toList()..sort(),
      requiredIdentifierTypes: requiredTypes.toList()..sort(),
      terminology: species.terminology,
      suppressed: suppressed,
    );
  }

  static bool _better((int, int) a, (int, int) b) => a.$1 != b.$1 ? a.$1 > b.$1 : a.$2 > b.$2;

  static String _normaliseSex(String? sex) {
    final code = (sex ?? '').trim().toUpperCase();
    return switch (code) {
      'F' || 'FEMALE' => Sex.female,
      'M' || 'MALE' => Sex.male,
      _ => Sex.unknown,
    };
  }
}
