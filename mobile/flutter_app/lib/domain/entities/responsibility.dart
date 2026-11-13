/// What an employee looks after and which duties that means
/// (`work_responsibilities`): a group, an animal, a species or a field;
/// milking, feeding, observations, health care, egg collection, crop care,
/// harvest. It routes the work — their day lists these animals and what is
/// still to record — and the server grants the module access the duties
/// need.
class WorkResponsibility {
  const WorkResponsibility({
    required this.id,
    required this.userId,
    required this.scopeType,
    required this.scopeId,
    required this.scopeName,
    required this.duties,
    required this.status,
    this.validFrom,
    this.notes,
    this.animals = const [],
  });

  final String id;
  final String userId;

  /// animal | group | species | field
  final String scopeType;
  final String scopeId;
  final String scopeName;
  final List<String> duties;
  final String status;
  final DateTime? validFrom;
  final String? notes;

  /// The animals it covers today (on `/me/responsibilities`).
  final List<ResponsibleAnimal> animals;

  bool get active => status == 'active';

  factory WorkResponsibility.fromJson(Map<String, dynamic> j) => WorkResponsibility(
        id: j['id'] as String,
        userId: j['user_id'] as String? ?? '',
        scopeType: j['scope_type'] as String? ?? 'group',
        scopeId: j['scope_id'] as String? ?? '',
        scopeName: j['scope_name'] as String? ?? '',
        duties: [for (final d in j['duties'] as List<dynamic>? ?? const []) d as String],
        status: j['status'] as String? ?? 'active',
        validFrom: j['valid_from'] == null ? null : DateTime.tryParse(j['valid_from'] as String),
        notes: j['notes'] as String?,
        animals: [
          for (final a in j['animals'] as List<dynamic>? ?? const [])
            if (a is Map) ResponsibleAnimal.fromJson(a.cast<String, dynamic>()),
        ],
      );
}

class ResponsibleAnimal {
  const ResponsibleAnimal({required this.id, required this.name, this.tag, required this.species, this.lactating = false});
  final String id;
  final String name;
  final String? tag;
  final String species;
  final bool lactating;

  factory ResponsibleAnimal.fromJson(Map<String, dynamic> j) => ResponsibleAnimal(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        tag: j['tag'] as String?,
        species: j['species'] as String? ?? '',
        lactating: j['lactating'] == true,
      );
}

/// The duties a responsibility can carry, per scope.
const kAnimalDuties = ['milking', 'feeding', 'observation', 'health_care', 'egg_collection'];
const kFieldDuties = ['crop_care', 'harvest', 'observation'];
