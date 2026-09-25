import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/livestock.dart';
import 'package:farmos/livestock/capability_resolver.dart';

/// Mirrors `backend/tests/test_livestock.py::TestResolver`, case for
/// case, against the *real* configuration rows the server ships in the
/// demo snapshot. The tablet and the server must give the same answer to
/// "what can this animal do" — this is where that is checked.
void main() {
  late Map<String, dynamic> snapshot;
  late List<CapabilityDef> catalog;

  SpeciesConfiguration config(String code) =>
      SpeciesConfiguration.fromJson(snapshot['GET /species/$code/configuration'] as Map<String, dynamic>);

  CapabilitySet resolve(String species, String? sex, {String? stage, String? profile}) => CapabilityResolver.resolve(
        configuration: config(species),
        catalog: catalog,
        sex: sex,
        lifeStage: stage,
        managementProfile: profile,
      );

  setUpAll(() async {
    snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
    catalog = [for (final c in snapshot['GET /capabilities'] as List<dynamic>) CapabilityDef.fromJson(c as Map<String, dynamic>)];
  });

  group('the §3 configuration table', () {
    test('dairy cow', () {
      final cs = resolve('cow', 'F', stage: 'adult', profile: 'dairy');
      for (final code in [Cap.earTag, Cap.breeding, Cap.pregnancy, Cap.liveBirth, Cap.milkProduction, Cap.lactation, Cap.health]) {
        expect(cs.has(code), isTrue, reason: code);
      }
      expect(cs.has(Cap.eggProduction), isFalse);
      expect(cs.requiredIdentifierTypes, ['EAR_TAG']);
      expect(cs.subjectKind, 'individual');
    });

    test('bull: biology removes pregnancy and milk, and says so', () {
      final cs = resolve('cow', 'M', stage: 'adult', profile: 'breeding');
      expect(cs.has(Cap.breeding), isTrue);
      expect(cs.has(Cap.pregnancy), isFalse);
      expect(cs.has(Cap.milkProduction), isFalse);
      expect(cs.suppressed, contains(Cap.pregnancy));
    });

    test('meat ewe reproduces but is not milked; dairy ewe is', () {
      final meat = resolve('sheep', 'F', stage: 'adult', profile: 'meat');
      expect(meat.has(Cap.pregnancy), isTrue);
      expect(meat.has(Cap.milkProduction), isFalse);
      expect(meat.isSuppressed(Cap.milkProduction), isFalse, reason: 'configuration, not biology');
      expect(resolve('sheep', 'F', stage: 'adult', profile: 'dairy').has(Cap.milkProduction), isTrue);
    });

    test('mare: microchip required, farrier, no dairy line, no ear tag', () {
      final cs = resolve('horse', 'F', stage: 'adult', profile: 'breeding');
      expect(cs.has(Cap.pregnancy), isTrue);
      expect(cs.has(Cap.hoofCare), isTrue);
      expect(cs.has(Cap.milkProduction), isFalse);
      expect(cs.requiredIdentifierTypes, ['MICROCHIP']);
      expect(cs.allowedIdentifierTypes, isNot(contains('EAR_TAG')));
      expect(cs.allowedIdentifierTypes, contains('PASSPORT'));
    });

    test('layer hen lays and never has a pregnancy record', () {
      final cs = resolve('layer_hen', 'F', stage: 'adult', profile: 'layer');
      expect(cs.has(Cap.eggProduction), isTrue);
      expect(cs.has(Cap.pregnancy), isFalse);
      expect(cs.suppressed, contains(Cap.pregnancy));
      expect(cs.allowedIdentifierTypes, contains('LEG_BAND'));
    });

    test('a broiler flock grows and does not lay (the veto)', () {
      final cs = resolve('layer_hen', 'F', stage: 'adult', profile: 'broiler');
      expect(cs.has(Cap.growthTracking), isTrue);
      expect(cs.has(Cap.eggProduction), isFalse);
      expect(cs.has(Cap.breeding), isFalse);
    });

    test('terminology follows the species', () {
      expect(resolve('cow', 'F').term('birth', 'en'), 'Calving');
      expect(resolve('sheep', 'F').term('birth', 'en'), 'Lambing');
      expect(resolve('goat', 'F').term('birth', 'en'), 'Kidding');
      expect(resolve('horse', 'F').term('birth', 'en'), 'Foaling');
      expect(resolve('goat', 'F').term('birth', 'ar'), isNotEmpty);
    });

    test('the spelling the spec uses is accepted', () {
      expect(resolve('cow', 'FEMALE').sex, 'F');
      expect(resolve('cow', 'male').sex, 'M');
      expect(resolve('cow', null).sex, 'U');
    });
  });

  group('device and server agree', () {
    test('Bella resolves on the tablet exactly as the server resolved her', () {
      final server = CapabilitySet.fromJson(snapshot['GET /animals/cow-744/capabilities'] as Map<String, dynamic>);
      final device = resolve(server.species, server.sex, stage: server.lifeStage, profile: server.managementProfile);
      expect(device.capabilities.map((c) => c.code).toSet(), server.capabilities.map((c) => c.code).toSet());
      expect(device.requiredIdentifierTypes, server.requiredIdentifierTypes);
      expect(device.suppressed, server.suppressed);
      expect(device.subjectKind, server.subjectKind);
    });

    test('every seeded animal agrees', () {
      final animals = snapshot['GET /animals?farm_id=farm-origami'] as List<dynamic>;
      for (final a in animals) {
        final animal = a as Map<String, dynamic>;
        final server = CapabilitySet.fromJson(snapshot['GET /animals/${animal['id']}/capabilities'] as Map<String, dynamic>);
        final device = resolve(server.species, server.sex, stage: server.lifeStage, profile: server.managementProfile);
        expect(device.capabilities.map((c) => c.code).toSet(), server.capabilities.map((c) => c.code).toSet(),
            reason: animal['name'] as String);
      }
    });
  });

  group('species configuration', () {
    test('a horse is not offered broiler', () {
      expect(config('horse').managementProfiles.map((p) => p.code), isNot(contains('broiler')));
      expect(config('layer_hen').managementProfiles.map((p) => p.code), isNot(contains('dairy')));
    });

    test('identifiers came through as typed rows', () {
      final bella = snapshot['GET /animals/cow-744'] as Map<String, dynamic>;
      final ids = [for (final i in bella['identifiers'] as List<dynamic>) AnimalIdentifier.fromJson(i as Map<String, dynamic>)];
      expect(ids.single.type, 'EAR_TAG');
      expect(ids.single.value, '744');
      expect(ids.single.isPrimary, isTrue);
    });
  });
}
