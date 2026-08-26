/// Mirrors the backend's `UserProfileOut` (schemas/users.py) — the shape
/// returned by /auth/login, /auth/me and GET /users.
///
/// `department` is a mobile-layout/task-assignment concern only (which
/// nav entries this account sees, who a task can be assigned to for a
/// given area) — it never gates a backend permission; `role` still does.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.farmId,
    required this.name,
    this.email,
    this.phone,
    required this.role,
    this.department,
    required this.language,
    required this.active,
  });

  final String id;
  final String farmId;
  final String name;
  final String? email;
  final String? phone;
  final String role;
  final String? department;
  final String language;
  final bool active;

  bool get isManager => role == 'owner' || role == 'manager';

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        farmId: json['farm_id'] as String,
        name: json['name'] as String,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        role: json['role'] as String,
        department: json['department'] as String?,
        language: json['language'] as String? ?? 'en',
        active: json['active'] as bool? ?? true,
      );
}
