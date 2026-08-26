import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/notification.dart';

/// The notification bell (tech spec §3) and the Today's Priorities feed
/// (§5), which the backend derives from the same live farm state.
class NotificationsProvider extends ChangeNotifier {
  NotificationsProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  List<FarmNotification> _notifications = [];
  List<FarmPriority> _priorities = [];
  Map<String, int> _countsByPriority = {};
  Map<String, int> _countsByModule = {};
  int unreadCount = 0;
  bool loading = false;
  String? error;

  List<FarmNotification> get notifications => List.unmodifiable(_notifications);
  List<FarmNotification> get unread => _notifications.where((n) => !n.isRead).toList();
  List<FarmPriority> get priorities => List.unmodifiable(_priorities);
  Map<String, int> get countsByPriority => Map.unmodifiable(_countsByPriority);
  Map<String, int> get countsByModule => Map.unmodifiable(_countsByModule);

  /// Modules that actually have something in the feed — what the filter
  /// chips offer, so a farm never sees a chip that filters to nothing.
  List<String> get modulesInFeed => _countsByModule.keys.toList()..sort();

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/notifications'),
        _api.get('/priorities'),
      ]);
      final bell = results[0] as Map<String, dynamic>;
      unreadCount = bell['unread_count'] as int? ?? 0;
      _notifications = (bell['notifications'] as List<dynamic>)
          .map((e) => FarmNotification.fromJson(e as Map<String, dynamic>))
          .toList();

      final feed = results[1] as Map<String, dynamic>;
      _priorities =
          (feed['priorities'] as List<dynamic>).map((e) => FarmPriority.fromJson(e as Map<String, dynamic>)).toList();
      _countsByPriority = Map<String, int>.from(feed['counts_by_priority'] as Map? ?? {});
      _countsByModule = Map<String, int>.from(feed['counts_by_module'] as Map? ?? {});
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Server-side filtered priorities, for the expanded view. Kept separate
  /// from [load] so filtering never disturbs the badge counts the rest of
  /// the app is showing.
  Future<List<FarmPriority>> fetchPriorities({
    String? module,
    String? priority,
    String? kind,
    String? assignment,
  }) async {
    final json = await _api.get('/priorities', query: {
      if (module != null) 'module': module,
      if (priority != null) 'priority': priority,
      if (kind != null) 'kind': kind,
      if (assignment != null) 'assignment': assignment,
    }) as Map<String, dynamic>;
    return (json['priorities'] as List<dynamic>).map((e) => FarmPriority.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> markRead(String notificationId) async {
    final index = _notifications.indexWhere((n) => n.id == notificationId);
    if (index == -1 || _notifications[index].isRead) return;
    // Optimistic: the badge should drop the instant it is tapped. A failed
    // call is corrected by the next load rather than blocking the tap.
    _notifications[index] = _notifications[index].copyWith(readAt: DateTime.now());
    unreadCount = (unreadCount - 1).clamp(0, 1 << 30);
    notifyListeners();
    await _api.write(() => _api.post('/notifications/$notificationId/read'));
  }

  Future<void> markAllRead() async {
    final result = await _api.write(() => _api.post('/notifications/read-all'));
    if (result.success) await load();
  }
}
