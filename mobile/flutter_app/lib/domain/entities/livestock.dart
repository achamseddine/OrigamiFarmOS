/// The generic animal model (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md):
/// species as data, capabilities resolved from configuration, identifiers
/// as typed rows.
///
/// Nothing in here is an enum of animals. The tablet learns what species
/// exist from `GET /species`, what each can do from its rules, and draws
/// exactly that — so a farm that starts keeping camels gets a working Add
/// Animal form the day the server's catalog says so.
library;

/// Capability codes, matching `backend/app/livestock/catalog.py`.
class Cap {
  static const earTag = 'EAR_TAG';
  static const rfid = 'RFID';
  static const microchip = 'MICROCHIP';
  static const legBand = 'LEG_BAND';
  static const passport = 'PASSPORT';
  static const individualTracking = 'INDIVIDUAL_TRACKING';
  static const groupTracking = 'GROUP_TRACKING';
  static const breeding = 'BREEDING';
  static const pregnancy = 'PREGNANCY';
  static const liveBirth = 'LIVE_BIRTH';
  static const incubation = 'INCUBATION';
  static const hatching = 'HATCHING';
  static const milkProduction = 'MILK_PRODUCTION';
  static const lactation = 'LACTATION';
  static const eggProduction = 'EGG_PRODUCTION';
  static const woolProduction = 'WOOL_PRODUCTION';
  static const growthTracking = 'GROWTH_TRACKING';
  static const weightTracking = 'WEIGHT_TRACKING';
  static const bodyCondition = 'BODY_CONDITION';
  static const hoofCare = 'HOOF_CARE';
  static const health = 'HEALTH';
  static const feed = 'FEED';
  static const mortality = 'MORTALITY';
}

/// Identifier types. The first five each need the matching capability;
/// the rest are always allowed — every animal may be called something.
class IdentifierType {
  static const earTag = 'EAR_TAG';
  static const rfid = 'RFID';
  static const microchip = 'MICROCHIP';
  static const legBand = 'LEG_BAND';
  static const passport = 'PASSPORT';
  static const name = 'NAME';
  static const farmNumber = 'FARM_NUMBER';
  static const registrationNumber = 'REGISTRATION_NUMBER';
  static const other = 'OTHER';

  static const alwaysAllowed = {name, farmNumber, registrationNumber, other};

  /// The order a form lays identifier fields out in: what is read off the
  /// animal first, the paperwork after. `NAME` is not here — the animal's
  /// name is its own field.
  static const fieldOrder = [earTag, rfid, microchip, legBand, passport, farmNumber, registrationNumber, other];
  static const forCapability = {
    Cap.earTag: earTag,
    Cap.rfid: rfid,
    Cap.microchip: microchip,
    Cap.legBand: legBand,
    Cap.passport: passport,
  };
}

/// Sex codes as the API stores them. `U` is the spec's explicit unknown.
class Sex {
  static const female = 'F';
  static const male = 'M';
  static const unknown = 'U';
}

const String kDefaultLifeStage = 'adult';

class Species {
  const Species({
    required this.code,
    required this.nameEn,
    required this.nameAr,
    required this.reproductionMode,
    required this.icon,
    required this.defaultManagement,
    required this.terminology,
    required this.profiles,
    required this.sortOrder,
  });

  final String code;
  final String nameEn;
  final String nameAr;

  /// viviparous | oviparous | unspecified — drives the resolver's
  /// biological invariants.
  final String reproductionMode;

  /// A hint for the icon map (cow, goat, sheep, horse, poultry, duck, barn).
  final String icon;

  /// individual | group | either.
  final String defaultManagement;

  /// birth_en/ar, offspring_en/ar, group_en/ar, female_en/ar, male_en/ar.
  final Map<String, String> terminology;

  /// Management profile codes this species is offered; empty means all.
  final List<String> profiles;
  final int sortOrder;

  String name(String languageCode) => languageCode == 'ar' ? nameAr : nameEn;

  /// "Calving" for cattle, "Foaling" for a horse — the generic event is
  /// `birth`; the word on the screen is the farm's.
  String term(String key, String languageCode, {String fallback = ''}) =>
      terminology['${key}_${languageCode == 'ar' ? 'ar' : 'en'}'] ?? terminology['${key}_en'] ?? fallback;

  bool get isOviparous => reproductionMode == 'oviparous';
  bool get isViviparous => reproductionMode == 'viviparous';

  factory Species.fromJson(Map<String, dynamic> json) => Species(
        code: json['code'] as String,
        nameEn: json['name_en'] as String,
        nameAr: json['name_ar'] as String? ?? json['name_en'] as String,
        reproductionMode: json['reproduction_mode'] as String? ?? 'unspecified',
        icon: json['icon'] as String? ?? 'barn',
        defaultManagement: json['default_management'] as String? ?? 'either',
        terminology: {
          for (final e in (json['terminology_json'] as Map<String, dynamic>? ?? const {}).entries)
            e.key: e.value?.toString() ?? '',
        },
        profiles: [for (final p in (json['profiles_json'] as List<dynamic>? ?? const [])) p as String],
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 100,
      );
}

class Breed {
  const Breed({required this.id, required this.speciesCode, required this.name, this.nameAr});
  final String id;
  final String speciesCode;
  final String name;
  final String? nameAr;

  String label(String languageCode) => languageCode == 'ar' && (nameAr?.isNotEmpty ?? false) ? nameAr! : name;

  factory Breed.fromJson(Map<String, dynamic> json) => Breed(
        id: json['id'] as String,
        speciesCode: json['species_code'] as String,
        name: json['name'] as String,
        nameAr: json['name_ar'] as String?,
      );
}

class LifeStage {
  const LifeStage({required this.code, required this.labelEn, required this.labelAr, required this.sortOrder});
  final String code;
  final String labelEn;
  final String labelAr;
  final int sortOrder;

  String label(String languageCode) => languageCode == 'ar' ? labelAr : labelEn;

  factory LifeStage.fromJson(Map<String, dynamic> json) => LifeStage(
        code: json['code'] as String,
        labelEn: json['label_en'] as String,
        labelAr: json['label_ar'] as String? ?? json['label_en'] as String,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 100,
      );
}

class ManagementProfile {
  const ManagementProfile({required this.code, required this.labelEn, required this.labelAr});
  final String code;
  final String labelEn;
  final String labelAr;

  String label(String languageCode) => languageCode == 'ar' ? labelAr : labelEn;

  factory ManagementProfile.fromJson(Map<String, dynamic> json) => ManagementProfile(
        code: json['code'] as String,
        labelEn: json['label_en'] as String,
        labelAr: json['label_ar'] as String? ?? json['label_en'] as String,
      );
}

class CapabilityDef {
  const CapabilityDef({required this.code, required this.category, required this.labelEn, required this.labelAr});
  final String code;
  final String category;
  final String labelEn;
  final String labelAr;

  String label(String languageCode) => languageCode == 'ar' ? labelAr : labelEn;

  factory CapabilityDef.fromJson(Map<String, dynamic> json) => CapabilityDef(
        code: json['code'] as String,
        category: json['category'] as String? ?? 'management',
        labelEn: json['label_en'] as String,
        labelAr: json['label_ar'] as String? ?? json['label_en'] as String,
      );
}

/// One line of configuration, exactly as the server stores it.
class CapabilityRule {
  const CapabilityRule({
    required this.capabilityCode,
    this.sex,
    this.lifeStage,
    this.managementProfile,
    required this.enabled,
    required this.required,
    this.configuration,
    required this.priority,
  });

  final String capabilityCode;
  final String? sex;
  final String? lifeStage;
  final String? managementProfile;
  final bool enabled;
  final bool required;
  final Map<String, dynamic>? configuration;
  final int priority;

  int get specificity => (sex != null ? 1 : 0) + (lifeStage != null ? 1 : 0) + (managementProfile != null ? 1 : 0);

  factory CapabilityRule.fromJson(Map<String, dynamic> json) => CapabilityRule(
        capabilityCode: json['capability_code'] as String,
        sex: json['sex'] as String?,
        lifeStage: json['life_stage'] as String?,
        managementProfile: json['management_profile'] as String?,
        enabled: json['enabled'] as bool? ?? true,
        required: json['required'] as bool? ?? false,
        configuration: json['configuration_json'] as Map<String, dynamic>?,
        priority: (json['priority'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /species/{code}/configuration` — everything the Add Animal flow
/// needs for one species, and everything the on-device resolver needs.
class SpeciesConfiguration {
  const SpeciesConfiguration({
    required this.species,
    required this.breeds,
    required this.lifeStages,
    required this.managementProfiles,
    required this.rules,
  });

  final Species species;
  final List<Breed> breeds;
  final List<LifeStage> lifeStages;
  final List<ManagementProfile> managementProfiles;
  final List<CapabilityRule> rules;

  factory SpeciesConfiguration.fromJson(Map<String, dynamic> json) => SpeciesConfiguration(
        species: Species.fromJson(json['species'] as Map<String, dynamic>),
        breeds: [for (final b in json['breeds'] as List<dynamic>) Breed.fromJson(b as Map<String, dynamic>)],
        lifeStages: [for (final s in json['life_stages'] as List<dynamic>) LifeStage.fromJson(s as Map<String, dynamic>)],
        managementProfiles: [
          for (final p in json['management_profiles'] as List<dynamic>) ManagementProfile.fromJson(p as Map<String, dynamic>),
        ],
        rules: [for (final r in json['rules'] as List<dynamic>) CapabilityRule.fromJson(r as Map<String, dynamic>)],
      );
}

class ResolvedCapability {
  const ResolvedCapability({
    required this.code,
    required this.category,
    required this.labelEn,
    required this.labelAr,
    required this.required,
    this.configuration,
  });

  final String code;
  final String category;
  final String labelEn;
  final String labelAr;
  final bool required;
  final Map<String, dynamic>? configuration;

  String label(String languageCode) => languageCode == 'ar' ? labelAr : labelEn;

  factory ResolvedCapability.fromJson(Map<String, dynamic> json) => ResolvedCapability(
        code: json['code'] as String,
        category: json['category'] as String? ?? 'management',
        labelEn: json['label_en'] as String? ?? json['code'] as String,
        labelAr: json['label_ar'] as String? ?? json['label_en'] as String? ?? json['code'] as String,
        required: json['required'] as bool? ?? false,
        configuration: json['configuration'] as Map<String, dynamic>?,
      );
}

/// What one animal (or one hypothetical animal in the Add form) can
/// participate in. Produced by the server for an existing animal and by
/// [CapabilityResolver] on the device for one being registered — the same
/// rules, so the two never disagree.
class CapabilitySet {
  const CapabilitySet({
    required this.species,
    required this.sex,
    required this.lifeStage,
    required this.managementProfile,
    required this.reproductionMode,
    required this.subjectKind,
    required this.capabilities,
    required this.allowedIdentifierTypes,
    required this.requiredIdentifierTypes,
    required this.terminology,
    required this.suppressed,
  });

  final String species;
  final String? sex;
  final String? lifeStage;
  final String? managementProfile;
  final String reproductionMode;

  /// individual | group | either.
  final String subjectKind;
  final List<ResolvedCapability> capabilities;
  final List<String> allowedIdentifierTypes;
  final List<String> requiredIdentifierTypes;
  final Map<String, String> terminology;

  /// What biology ruled out for this animal, so a screen can say why a
  /// tab is missing instead of just omitting it.
  final List<String> suppressed;

  static const empty = CapabilitySet(
    species: '', sex: null, lifeStage: null, managementProfile: null, reproductionMode: 'unspecified',
    subjectKind: 'individual', capabilities: [], allowedIdentifierTypes: [], requiredIdentifierTypes: [],
    terminology: {}, suppressed: [],
  );

  bool has(String code) => capabilities.any((c) => c.code == code);
  bool isRequired(String code) => capabilities.any((c) => c.code == code && c.required);
  bool isSuppressed(String code) => suppressed.contains(code);
  Iterable<ResolvedCapability> inCategory(String category) => capabilities.where((c) => c.category == category);

  String term(String key, String languageCode, {String fallback = ''}) =>
      terminology['${key}_${languageCode == 'ar' ? 'ar' : 'en'}'] ?? terminology['${key}_en'] ?? fallback;

  factory CapabilitySet.fromJson(Map<String, dynamic> json) => CapabilitySet(
        species: json['species'] as String? ?? '',
        sex: json['sex'] as String?,
        lifeStage: json['life_stage'] as String?,
        managementProfile: json['management_profile'] as String?,
        reproductionMode: json['reproduction_mode'] as String? ?? 'unspecified',
        subjectKind: json['subject_kind'] as String? ?? 'individual',
        capabilities: [
          for (final c in json['capabilities'] as List<dynamic>? ?? const [])
            ResolvedCapability.fromJson(c as Map<String, dynamic>),
        ],
        allowedIdentifierTypes: [for (final t in json['allowed_identifier_types'] as List<dynamic>? ?? const []) t as String],
        requiredIdentifierTypes: [for (final t in json['required_identifier_types'] as List<dynamic>? ?? const []) t as String],
        terminology: {
          for (final e in (json['terminology'] as Map<String, dynamic>? ?? const {}).entries) e.key: e.value?.toString() ?? '',
        },
        suppressed: [for (final s in json['suppressed'] as List<dynamic>? ?? const []) s as String],
      );
}

/// An identifier an animal carries — one row per ear tag, RFID, microchip,
/// leg band, passport, name… (generic animal model §4).
class AnimalIdentifier {
  const AnimalIdentifier({
    required this.id,
    required this.type,
    required this.value,
    this.issuingAuthority,
    required this.isPrimary,
    required this.status,
  });

  final String id;
  final String type;
  final String value;
  final String? issuingAuthority;
  final bool isPrimary;

  /// active | retired — a replaced tag is retired, never erased.
  final String status;

  bool get isActive => status == 'active';

  factory AnimalIdentifier.fromJson(Map<String, dynamic> json) => AnimalIdentifier(
        id: json['id'] as String? ?? '',
        type: json['identifier_type'] as String,
        value: json['identifier_value'] as String,
        issuingAuthority: json['issuing_authority'] as String?,
        isPrimary: json['is_primary'] as bool? ?? false,
        status: json['status'] as String? ?? 'active',
      );

  Map<String, dynamic> toJson() => {
        'identifier_type': type,
        'identifier_value': value,
        if (issuingAuthority != null && issuingAuthority!.isNotEmpty) 'issuing_authority': issuingAuthority,
        'is_primary': isPrimary,
      };
}

/// A herd, flock, batch or pen managed as one unit (§7).
class AnimalGroup {
  const AnimalGroup({
    required this.id,
    required this.name,
    required this.species,
    required this.groupType,
    required this.count,
    this.sexComposition,
    this.lifeStage,
    this.managementProfile,
    required this.status,
    this.location,
  });

  final String id;
  final String name;
  final String species;
  final String groupType;
  final int count;
  final String? sexComposition;
  final String? lifeStage;
  final String? managementProfile;
  final String status;
  final String? location;

  factory AnimalGroup.fromJson(Map<String, dynamic> json) => AnimalGroup(
        id: json['id'] as String,
        name: json['name'] as String,
        species: json['species'] as String,
        groupType: json['group_type'] as String? ?? 'flock',
        count: (json['count'] as num?)?.toInt() ?? 0,
        sexComposition: json['sex_composition'] as String?,
        lifeStage: json['life_stage'] as String?,
        managementProfile: json['management_profile'] as String?,
        status: json['status'] as String? ?? 'healthy',
        location: json['location_label'] as String?,
      );
}
