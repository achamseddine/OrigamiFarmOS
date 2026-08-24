class Farm {
  const Farm({
    required this.id,
    required this.name,
    required this.region,
    required this.country,
    required this.timezone,
    required this.defaultCurrency,
  });

  final String id;
  final String name;
  final String region;
  final String country;
  final String timezone;
  final String defaultCurrency;
}

class FarmLocation {
  const FarmLocation({
    required this.id,
    required this.farmId,
    required this.name,
    required this.type,
    this.parentId,
  });

  final String id;
  final String farmId;
  final String name;
  final String type;
  final String? parentId;
}

enum UserRole { owner, manager, worker, veterinarian, accountant, readOnly }

class AppUser {
  const AppUser({
    required this.id,
    required this.farmId,
    required this.name,
    required this.role,
    required this.language,
    this.active = true,
  });

  final String id;
  final String farmId;
  final String name;
  final UserRole role;
  final String language;
  final bool active;

  bool get canDiagnose => role == UserRole.manager || role == UserRole.veterinarian || role == UserRole.owner;
}
